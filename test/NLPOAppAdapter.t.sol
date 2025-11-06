// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test, console} from "forge-std/Test.sol";
import {NLPOAppAdapter} from "../src/NLPOAppAdapter.sol";
import {NLPMinterBurner} from "../src/NLPMinterBurner.sol";
import {MessagingFee, MessagingReceipt} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";

// Mock contracts
contract MockNLPToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => uint256) public nonces;

    string public name = "NewLoPoint";
    bytes32 public DOMAIN_SEPARATOR;

    constructor() {
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

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

    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
    {
        require(block.timestamp <= deadline, "Permit expired");
        allowance[owner][spender] = value;
        nonces[owner]++;
    }
}

// Simple struct for MessagingParams
struct MessagingParams {
    uint32 dstEid;
    bytes32 receiver;
    bytes message;
    bytes options;
    bool payInLzToken;
}

contract MockLZEndpoint {
    uint32 public constant EID = 30109; // Mock Polygon EID
    mapping(address => address) public delegates;

    function eid() external pure returns (uint32) {
        return EID;
    }

    function setDelegate(address _delegate) external {
        delegates[msg.sender] = _delegate;
    }

    function send(MessagingParams calldata, address) external payable returns (MessagingReceipt memory) {
        return MessagingReceipt({guid: bytes32(0), nonce: 0, fee: MessagingFee(msg.value, 0)});
    }

    function quote(MessagingParams calldata, address) external pure returns (MessagingFee memory) {
        return MessagingFee(0.01 ether, 0);
    }
}

/**
 * @title NLPOAppAdapterTest
 * @notice Test suite for NLPOAppAdapter contract
 */
contract NLPOAppAdapterTest is Test {
    NLPOAppAdapter public adapter;
    NLPMinterBurner public minterBurner;
    MockNLPToken public nlpToken;
    MockLZEndpoint public lzEndpoint;

    address public owner = address(this);
    address public user = address(0x1);
    uint32 public constant POLYGON_EID = 30109;

    event NLPLocked(address indexed user, uint256 amount, uint32 indexed dstEid);
    event NLPBurned(address indexed user, uint256 amount);
    event NLPUnlocked(address indexed user, uint256 amount);

    function setUp() public {
        // Deploy mocks
        nlpToken = new MockNLPToken();
        lzEndpoint = new MockLZEndpoint();

        // Deploy real contracts
        minterBurner = new NLPMinterBurner(address(nlpToken), owner);
        adapter = new NLPOAppAdapter(address(nlpToken), address(minterBurner), address(lzEndpoint), owner);

        // Setup
        minterBurner.setOperator(address(adapter), true);

        // Give user some NLP
        nlpToken.mint(user, 1000 ether);

        // Give user some ETH for fees
        vm.deal(user, 10 ether);

        // Configure peer
        adapter.setPeer(POLYGON_EID, bytes32(uint256(uint160(address(0x2)))));
    }

    function testSendWithApproval() public {
        vm.startPrank(user);

        uint256 sendAmount = 100 ether;
        address recipient = address(0x3);

        // Approve adapter
        nlpToken.approve(address(adapter), sendAmount);

        // Send
        vm.expectEmit(true, true, false, true);
        emit NLPLocked(user, sendAmount, POLYGON_EID);

        adapter.send{value: 0.01 ether}(POLYGON_EID, recipient, sendAmount, "");

        // Check locked balance
        assertEq(adapter.lockedBalances(user), sendAmount);
        assertEq(nlpToken.balanceOf(address(adapter)), sendAmount);
        assertEq(nlpToken.balanceOf(user), 900 ether);

        vm.stopPrank();
    }

    function testGetExchangeQuote() public view {
        uint256 nlpAmount = 100 ether;
        uint256 expectedJpyc = 100 ether; // 1:1 rate

        uint256 quote = adapter.getExchangeQuote(nlpAmount);
        assertEq(quote, expectedJpyc);
    }

    function testSetExchangeRate() public {
        uint256 newRate = 9000; // 0.9:1
        adapter.setExchangeRate(newRate);
        assertEq(adapter.nlpToJpycRate(), newRate);

        uint256 nlpAmount = 100 ether;
        uint256 expectedJpyc = 90 ether;
        assertEq(adapter.getExchangeQuote(nlpAmount), expectedJpyc);
    }

    function testCannotSendZeroAmount() public {
        vm.startPrank(user);
        nlpToken.approve(address(adapter), 100 ether);

        vm.expectRevert(NLPOAppAdapter.InvalidAmount.selector);
        adapter.send{value: 0.01 ether}(POLYGON_EID, address(0x3), 0, "");

        vm.stopPrank();
    }

    function testCannotSendToZeroAddress() public {
        vm.startPrank(user);
        nlpToken.approve(address(adapter), 100 ether);

        vm.expectRevert(NLPOAppAdapter.InvalidAddress.selector);
        adapter.send{value: 0.01 ether}(POLYGON_EID, address(0), 100 ether, "");

        vm.stopPrank();
    }

    function testLockedBalanceTracking() public {
        vm.startPrank(user);

        nlpToken.approve(address(adapter), 300 ether);

        // First send
        adapter.send{value: 0.01 ether}(POLYGON_EID, address(0x3), 100 ether, "");
        assertEq(adapter.lockedBalances(user), 100 ether);

        // Second send
        adapter.send{value: 0.01 ether}(POLYGON_EID, address(0x3), 50 ether, "");
        assertEq(adapter.lockedBalances(user), 150 ether);

        vm.stopPrank();
    }
}
