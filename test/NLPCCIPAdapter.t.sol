// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test, console} from "forge-std/Test.sol";
import {NLPCCIPAdapter} from "../src/NLPCCIPAdapter.sol";
import {NLPMinterBurner} from "../src/NLPMinterBurner.sol";
import {Client} from "@chainlink/contracts-ccip/libraries/Client.sol";

// Mock contracts
contract MockNLPToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        require(balanceOf[from] >= amount, "Insufficient balance");

        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        require(block.timestamp <= deadline, "Permit expired");
        allowance[owner][spender] = value;
    }
}

contract MockCCIPRouter {
    function ccipSend(uint64, Client.EVM2AnyMessage calldata) external payable returns (bytes32) {
        return bytes32(uint256(1));
    }

    function getFee(uint64, Client.EVM2AnyMessage calldata) external pure returns (uint256) {
        return 0.01 ether;
    }

    function getRouter() external view returns (address) {
        return address(this);
    }
}

contract MockLinkToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/**
 * @title NLPCCIPAdapterTest
 * @notice Test suite for NLPCCIPAdapter contract
 */
contract NLPCCIPAdapterTest is Test {
    NLPCCIPAdapter public adapter;
    NLPMinterBurner public minterBurner;
    MockNLPToken public nlpToken;
    MockCCIPRouter public ccipRouter;
    MockLinkToken public linkToken;

    address public owner = address(this);
    address public user = address(0x1);
    uint64 public constant POLYGON_CHAIN_SELECTOR = 4051577828743386545;
    address public constant POLYGON_RECEIVER = address(0x2);

    event NLPLocked(address indexed user, uint256 amount, bytes32 indexed messageId);
    event NLPBurned(address indexed user, uint256 amount);
    event NLPUnlocked(address indexed user, uint256 amount);

    function setUp() public {
        // Deploy mocks
        nlpToken = new MockNLPToken();
        ccipRouter = new MockCCIPRouter();
        linkToken = new MockLinkToken();

        // Deploy real contracts
        minterBurner = new NLPMinterBurner(address(nlpToken), owner);
        adapter = new NLPCCIPAdapter(
            address(nlpToken),
            address(minterBurner),
            address(ccipRouter),
            address(linkToken),
            owner
        );

        // Setup
        minterBurner.setOperator(address(adapter), true);

        // Give user some NLP
        nlpToken.mint(user, 1000 ether);

        // Give user some ETH for fees
        vm.deal(user, 10 ether);

        // Configure destination
        adapter.configureDestination(POLYGON_CHAIN_SELECTOR, POLYGON_RECEIVER);

        // Give adapter some LINK for fees
        linkToken.mint(address(adapter), 10 ether);
    }

    function testSendWithNativeFee() public {
        vm.startPrank(user);

        uint256 sendAmount = 100 ether;
        address recipient = address(0x3);

        // Approve adapter
        nlpToken.approve(address(adapter), sendAmount);

        // Send with native fee
        vm.expectEmit(true, false, false, false);
        emit NLPLocked(user, sendAmount, bytes32(0));

        adapter.send{value: 0.01 ether}(
            recipient,
            sendAmount,
            false // pay in native
        );

        // Check locked balance
        assertEq(adapter.lockedBalances(user), sendAmount);
        assertEq(nlpToken.balanceOf(address(adapter)), sendAmount);
        assertEq(nlpToken.balanceOf(user), 900 ether);

        vm.stopPrank();
    }

    function testSendWithLinkFee() public {
        vm.startPrank(user);

        uint256 sendAmount = 100 ether;
        address recipient = address(0x3);

        // Approve adapter
        nlpToken.approve(address(adapter), sendAmount);

        // Send with LINK fee
        adapter.send(
            recipient,
            sendAmount,
            true // pay in LINK
        );

        // Check locked balance
        assertEq(adapter.lockedBalances(user), sendAmount);

        vm.stopPrank();
    }

    function testGetExchangeQuote() public view {
        uint256 nlpAmount = 100 ether;
        uint256 expectedJpyc = 100 ether; // 1:1 rate

        uint256 quote = adapter.getExchangeQuote(nlpAmount);
        assertEq(quote, expectedJpyc);
    }

    function testSetExchangeRate() public {
        uint256 newRate = 9500; // 0.95:1
        adapter.setExchangeRate(newRate);
        assertEq(adapter.nlpToJpycRate(), newRate);

        uint256 nlpAmount = 100 ether;
        uint256 expectedJpyc = 95 ether;
        assertEq(adapter.getExchangeQuote(nlpAmount), expectedJpyc);
    }

    function testCannotSendWithoutDestination() public {
        // Deploy new adapter without destination configured
        NLPCCIPAdapter newAdapter = new NLPCCIPAdapter(
            address(nlpToken),
            address(minterBurner),
            address(ccipRouter),
            address(linkToken),
            owner
        );

        vm.startPrank(user);
        nlpToken.approve(address(newAdapter), 100 ether);

        vm.expectRevert(NLPCCIPAdapter.DestinationNotConfigured.selector);
        newAdapter.send{value: 0.01 ether}(address(0x3), 100 ether, false);

        vm.stopPrank();
    }

    function testConfigureDestination() public {
        uint64 newChainSelector = 12345;
        address newReceiver = address(0x999);

        adapter.configureDestination(newChainSelector, newReceiver);

        assertEq(adapter.destinationChainSelector(), newChainSelector);
        assertEq(adapter.destinationReceiver(), newReceiver);
    }

    function testLockedBalanceTracking() public {
        vm.startPrank(user);

        nlpToken.approve(address(adapter), 300 ether);

        // First send
        adapter.send{value: 0.01 ether}(address(0x3), 100 ether, false);
        assertEq(adapter.lockedBalances(user), 100 ether);

        // Second send
        adapter.send{value: 0.01 ether}(address(0x3), 50 ether, false);
        assertEq(adapter.lockedBalances(user), 150 ether);

        vm.stopPrank();
    }
}
