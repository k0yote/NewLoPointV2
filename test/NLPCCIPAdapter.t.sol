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

    function burnFrom(address from, uint256 amount) external {
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        require(balanceOf[from] >= amount, "Insufficient balance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
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
            address(nlpToken), address(minterBurner), address(ccipRouter), address(linkToken), owner
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

    /* ═══════════════════════════════════════════════════════════════════════
                        FEE LOGIC TESTS
    ═══════════════════════════════════════════════════════════════════════ */

    function testGetExchangeQuote_NoFees() public view {
        uint256 nlpAmount = 1000 ether;

        (uint256 gross, uint256 exFee, uint256 opFee, uint256 net) =
            adapter.getExchangeQuote(NLPCCIPAdapter.TokenType.JPYC, nlpAmount);

        assertEq(gross, 1000 ether, "Gross amount should be 1000");
        assertEq(exFee, 0, "Exchange fee should be 0");
        assertEq(opFee, 0, "Operational fee should be 0");
        assertEq(net, 1000 ether, "Net amount should equal gross");
    }

    function testGetExchangeQuote_WithExchangeFee() public {
        // Set 1% exchange fee (100 basis points)
        adapter.setExchangeFee(100);

        uint256 nlpAmount = 1000 ether;

        (uint256 gross, uint256 exFee, uint256 opFee, uint256 net) =
            adapter.getExchangeQuote(NLPCCIPAdapter.TokenType.JPYC, nlpAmount);

        assertEq(gross, 1000 ether, "Gross should be 1000");
        assertEq(exFee, 10 ether, "Exchange fee should be 1% = 10");
        assertEq(opFee, 0, "Operational fee should be 0");
        assertEq(net, 990 ether, "Net should be 990");
    }

    function testGetExchangeQuote_WithBothFees() public {
        // Set 1% exchange fee and 0.5% operational fee
        adapter.setExchangeFee(100); // 1%
        adapter.setOperationalFee(50); // 0.5%

        uint256 nlpAmount = 1000 ether;

        (uint256 gross, uint256 exFee, uint256 opFee, uint256 net) =
            adapter.getExchangeQuote(NLPCCIPAdapter.TokenType.JPYC, nlpAmount);

        assertEq(gross, 1000 ether, "Gross should be 1000");
        assertEq(exFee, 10 ether, "Exchange fee should be 10");
        assertEq(opFee, 5 ether, "Operational fee should be 5");
        assertEq(net, 985 ether, "Net should be 985");
    }

    function testSetExchangeFee_Success() public {
        adapter.setExchangeFee(100);
        assertEq(adapter.exchangeFee(), 100, "Exchange fee should be updated");
    }

    function testSetExchangeFee_ExceedsMax() public {
        vm.expectRevert(abi.encodeWithSelector(NLPCCIPAdapter.InvalidFeeRate.selector, 501, 500));
        adapter.setExchangeFee(501); // MAX_FEE is 500
    }

    function testSetOperationalFee_Success() public {
        adapter.setOperationalFee(50);
        assertEq(adapter.operationalFee(), 50, "Operational fee should be updated");
    }

    function testSetOperationalFee_ExceedsMax() public {
        vm.expectRevert(abi.encodeWithSelector(NLPCCIPAdapter.InvalidFeeRate.selector, 600, 500));
        adapter.setOperationalFee(600);
    }

    function testSetFees_OnlyOwner() public {
        vm.startPrank(user);

        vm.expectRevert();
        adapter.setExchangeFee(100);

        vm.expectRevert();
        adapter.setOperationalFee(50);

        vm.stopPrank();
    }

    function testSetExchangeRate() public {
        uint256 newRate = 9500; // 0.95:1
        adapter.setExchangeRate(newRate);
        assertEq(adapter.nlpToJpycRate(), newRate);

        uint256 nlpAmount = 100 ether;
        uint256 expectedJpyc = 95 ether;
        (uint256 gross,,,) = adapter.getExchangeQuote(NLPCCIPAdapter.TokenType.JPYC, nlpAmount);
        assertEq(gross, expectedJpyc);
    }

    function testCannotSendWithoutDestination() public {
        // Deploy new adapter without destination configured
        NLPCCIPAdapter newAdapter = new NLPCCIPAdapter(
            address(nlpToken), address(minterBurner), address(ccipRouter), address(linkToken), owner
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

    /* ═══════════════════════════════════════════════════════════════════════
                        BURN/UNLOCK TESTS
    ═══════════════════════════════════════════════════════════════════════ */

    function testCcipReceive_Success_BurnsNLP() public {
        // Setup: Lock tokens first
        vm.startPrank(user);
        nlpToken.approve(address(adapter), 1000 ether);
        adapter.send{value: 0.01 ether}(address(0x3), 1000 ether, false);
        vm.stopPrank();

        uint256 userBalanceBefore = nlpToken.balanceOf(user);
        uint256 adapterBalance = nlpToken.balanceOf(address(adapter));

        assertEq(adapter.lockedBalances(user), 1000 ether, "Tokens should be locked");
        assertEq(adapterBalance, 1000 ether, "Adapter should hold locked tokens");

        // Simulate successful response from receiver
        NLPCCIPAdapter.ResponseMessage memory response =
            NLPCCIPAdapter.ResponseMessage({user: user, amount: 1000 ether, success: true});

        bytes memory messageData = abi.encode(NLPCCIPAdapter.MessageType.RESPONSE, abi.encode(response));

        Client.Any2EVMMessage memory ccipMessage = Client.Any2EVMMessage({
            messageId: bytes32(uint256(1)),
            sourceChainSelector: POLYGON_CHAIN_SELECTOR,
            sender: abi.encode(POLYGON_RECEIVER),
            data: messageData,
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.expectEmit(true, true, true, true);
        emit NLPBurned(user, 1000 ether);

        // Call ccipReceive
        vm.prank(address(ccipRouter));
        adapter.ccipReceive(ccipMessage);

        // Verify tokens were burned
        assertEq(nlpToken.balanceOf(address(adapter)), 0, "Adapter balance should be 0 after burn");
        assertEq(adapter.lockedBalances(user), 0, "Locked balance should be 0");
    }

    function testCcipReceive_Failure_UnlocksNLP() public {
        // Setup: Lock tokens
        vm.startPrank(user);
        nlpToken.approve(address(adapter), 1000 ether);
        adapter.send{value: 0.01 ether}(address(0x3), 1000 ether, false);
        vm.stopPrank();

        uint256 userBalanceBefore = nlpToken.balanceOf(user);

        // Simulate failed response
        NLPCCIPAdapter.ResponseMessage memory response =
            NLPCCIPAdapter.ResponseMessage({user: user, amount: 1000 ether, success: false});

        bytes memory messageData = abi.encode(NLPCCIPAdapter.MessageType.RESPONSE, abi.encode(response));

        Client.Any2EVMMessage memory ccipMessage = Client.Any2EVMMessage({
            messageId: bytes32(uint256(1)),
            sourceChainSelector: POLYGON_CHAIN_SELECTOR,
            sender: abi.encode(POLYGON_RECEIVER),
            data: messageData,
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.expectEmit(true, true, true, true);
        emit NLPUnlocked(user, 1000 ether);

        // Call ccipReceive
        vm.prank(address(ccipRouter));
        adapter.ccipReceive(ccipMessage);

        // Verify tokens were unlocked to user
        assertEq(nlpToken.balanceOf(user), userBalanceBefore + 1000 ether, "User should receive unlocked tokens");
        assertEq(nlpToken.balanceOf(address(adapter)), 0, "Adapter balance should be 0");
        assertEq(adapter.lockedBalances(user), 0, "Locked balance should be 0");
    }

    function testCcipReceive_RevertOnInvalidAmount() public {
        NLPCCIPAdapter.ResponseMessage memory response = NLPCCIPAdapter.ResponseMessage({
            user: user,
            amount: 0, // Invalid amount
            success: true
        });

        bytes memory messageData = abi.encode(NLPCCIPAdapter.MessageType.RESPONSE, abi.encode(response));

        Client.Any2EVMMessage memory ccipMessage = Client.Any2EVMMessage({
            messageId: bytes32(uint256(1)),
            sourceChainSelector: POLYGON_CHAIN_SELECTOR,
            sender: abi.encode(POLYGON_RECEIVER),
            data: messageData,
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.expectRevert(NLPCCIPAdapter.InvalidAmount.selector);
        vm.prank(address(ccipRouter));
        adapter.ccipReceive(ccipMessage);
    }

    function testCcipReceive_RevertOnNoLockedTokens() public {
        NLPCCIPAdapter.ResponseMessage memory response =
            NLPCCIPAdapter.ResponseMessage({user: user, amount: 1000 ether, success: true});

        bytes memory messageData = abi.encode(NLPCCIPAdapter.MessageType.RESPONSE, abi.encode(response));

        Client.Any2EVMMessage memory ccipMessage = Client.Any2EVMMessage({
            messageId: bytes32(uint256(1)),
            sourceChainSelector: POLYGON_CHAIN_SELECTOR,
            sender: abi.encode(POLYGON_RECEIVER),
            data: messageData,
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.expectRevert(NLPCCIPAdapter.NoLockedTokens.selector);
        vm.prank(address(ccipRouter));
        adapter.ccipReceive(ccipMessage);
    }

    /* ═══════════════════════════════════════════════════════════════════════
                        INTEGRATION TESTS
    ═══════════════════════════════════════════════════════════════════════ */

    function testFullFlow_WithFees() public {
        // Set fees
        adapter.setExchangeFee(100); // 1%
        adapter.setOperationalFee(50); // 0.5%

        // Get quote
        (uint256 gross, uint256 exFee, uint256 opFee, uint256 net) =
            adapter.getExchangeQuote(NLPCCIPAdapter.TokenType.JPYC, 1000 ether);

        // Verify quote calculation
        assertEq(gross, 1000 ether);
        assertEq(exFee, 10 ether);
        assertEq(opFee, 5 ether);
        assertEq(net, 985 ether);
    }

    function testExchangeRateChange_AffectsQuote() public {
        uint256 nlpAmount = 1000 ether;

        // Initial rate (1:1)
        (uint256 gross1,,,) = adapter.getExchangeQuote(NLPCCIPAdapter.TokenType.JPYC, nlpAmount);
        assertEq(gross1, 1000 ether);

        // Change rate to 0.9:1
        adapter.setExchangeRate(9000);

        (uint256 gross2,,,) = adapter.getExchangeQuote(NLPCCIPAdapter.TokenType.JPYC, nlpAmount);
        assertEq(gross2, 900 ether);
    }
}
