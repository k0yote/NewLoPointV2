// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test, console} from "forge-std/Test.sol";
import {NLPOAppJPYCReceiverV2} from "../src/NLPOAppJPYCReceiverV2.sol";
import {NLPCCIPJPYCReceiverV2} from "../src/NLPCCIPJPYCReceiverV2.sol";
import {Origin, MessagingReceipt, MessagingFee} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";

/**
 * @title ReceiverV2Test
 * @notice Test suite for V2 receivers (without JPYCVault dependency)
 */
contract ReceiverV2Test is Test {
    // Mock contracts
    MockERC20 public jpyc;
    MockLZEndpoint public lzEndpoint;

    // V2 Receivers
    NLPOAppJPYCReceiverV2 public oappReceiver;

    // Test addresses
    address public owner = makeAddr("owner");
    address public user = makeAddr("user");
    address public recipient = makeAddr("recipient");

    uint256 public constant INITIAL_JPYC = 1_000_000 * 1e18;
    uint256 public constant DEPOSIT_AMOUNT = 500_000 * 1e18;

    event JPYCDeposited(address indexed from, uint256 amount, uint256 newBalance);
    event JPYCWithdrawn(address indexed to, uint256 amount, uint256 newBalance);
    event JPYCTransferred(address indexed recipient, uint256 jpycAmount, uint256 nlpAmount);
    event JPYCTransferFailed(address indexed recipient, uint256 jpycAmount, uint256 nlpAmount, string reason);

    function setUp() public {
        // Deploy mock contracts
        jpyc = new MockERC20("JPY Coin", "JPYC");
        lzEndpoint = new MockLZEndpoint();

        // Deploy V2 receiver
        vm.prank(owner);
        oappReceiver = new NLPOAppJPYCReceiverV2(address(jpyc), address(lzEndpoint), owner);

        // Mint JPYC to owner
        jpyc.mint(owner, INITIAL_JPYC);
    }

    /* ═══════════════════════════════════════════════════════════════════════
                            JPYC MANAGEMENT TESTS
    ═══════════════════════════════════════════════════════════════════════ */

    function test_DepositJPYC_Success() public {
        // Approve receiver
        vm.prank(owner);
        jpyc.approve(address(oappReceiver), DEPOSIT_AMOUNT);

        // Deposit
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit JPYCDeposited(owner, DEPOSIT_AMOUNT, DEPOSIT_AMOUNT);
        oappReceiver.depositJPYC(DEPOSIT_AMOUNT);

        // Verify
        assertEq(oappReceiver.jpycBalance(), DEPOSIT_AMOUNT);
        assertEq(jpyc.balanceOf(address(oappReceiver)), DEPOSIT_AMOUNT);
        assertEq(jpyc.balanceOf(owner), INITIAL_JPYC - DEPOSIT_AMOUNT);
    }

    function test_DepositJPYC_OnlyOwner() public {
        vm.prank(user);
        jpyc.mint(user, DEPOSIT_AMOUNT);

        vm.prank(user);
        jpyc.approve(address(oappReceiver), DEPOSIT_AMOUNT);

        // Should revert - not owner
        vm.prank(user);
        vm.expectRevert();
        oappReceiver.depositJPYC(DEPOSIT_AMOUNT);
    }

    function test_DepositJPYC_ZeroAmount() public {
        vm.prank(owner);
        vm.expectRevert(NLPOAppJPYCReceiverV2.InvalidAmount.selector);
        oappReceiver.depositJPYC(0);
    }

    function test_WithdrawJPYC_Success() public {
        // First deposit
        vm.startPrank(owner);
        jpyc.approve(address(oappReceiver), DEPOSIT_AMOUNT);
        oappReceiver.depositJPYC(DEPOSIT_AMOUNT);
        vm.stopPrank();

        // Withdraw
        uint256 withdrawAmount = 100_000 * 1e18;

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit JPYCWithdrawn(recipient, withdrawAmount, DEPOSIT_AMOUNT - withdrawAmount);
        oappReceiver.withdrawJPYC(recipient, withdrawAmount);

        // Verify
        assertEq(jpyc.balanceOf(recipient), withdrawAmount);
        assertEq(oappReceiver.jpycBalance(), DEPOSIT_AMOUNT - withdrawAmount);
    }

    function test_WithdrawJPYC_InsufficientBalance() public {
        // Try to withdraw more than balance
        vm.prank(owner);
        vm.expectRevert();
        oappReceiver.withdrawJPYC(recipient, 1000);
    }

    function test_JPYCBalance() public {
        assertEq(oappReceiver.jpycBalance(), 0);

        // Deposit
        vm.startPrank(owner);
        jpyc.approve(address(oappReceiver), DEPOSIT_AMOUNT);
        oappReceiver.depositJPYC(DEPOSIT_AMOUNT);
        vm.stopPrank();

        assertEq(oappReceiver.jpycBalance(), DEPOSIT_AMOUNT);
    }

    /* ═══════════════════════════════════════════════════════════════════════
                            MESSAGE HANDLING TESTS
    ═══════════════════════════════════════════════════════════════════════ */

    function test_ReceiveAndTransferJPYC_Success() public {
        // Setup: Deposit JPYC into receiver
        vm.startPrank(owner);
        jpyc.approve(address(oappReceiver), DEPOSIT_AMOUNT);
        oappReceiver.depositJPYC(DEPOSIT_AMOUNT);
        vm.stopPrank();

        // Setup peer
        uint32 srcEid = 40161; // Mock source EID
        address adapterAddress = makeAddr("adapter");
        bytes32 peer = bytes32(uint256(uint160(adapterAddress)));

        vm.prank(owner);
        oappReceiver.setPeer(srcEid, peer);

        // Build message
        uint256 nlpAmount = 100_000 * 1e18;
        NLPOAppJPYCReceiverV2.GiftMessage memory gift =
            NLPOAppJPYCReceiverV2.GiftMessage({recipient: recipient, amount: nlpAmount});

        bytes memory message = abi.encode(NLPOAppJPYCReceiverV2.MessageType.REQUEST, abi.encode(gift));

        // Fund receiver with native tokens for response
        vm.deal(address(oappReceiver), 1 ether);

        // Simulate receiving message
        Origin memory origin = Origin({srcEid: srcEid, sender: peer, nonce: 1});

        // Expect JPYCTransferred event
        vm.expectEmit(true, true, true, true);
        emit JPYCTransferred(recipient, nlpAmount, nlpAmount);

        // Call lzReceive
        vm.prank(address(lzEndpoint));
        oappReceiver.lzReceive(origin, bytes32(0), message, address(0), bytes(""));

        // Verify recipient received JPYC
        assertEq(jpyc.balanceOf(recipient), nlpAmount);
        assertEq(oappReceiver.jpycBalance(), DEPOSIT_AMOUNT - nlpAmount);
    }

    function test_ReceiveAndTransferJPYC_InsufficientBalance() public {
        // Don't deposit JPYC - receiver has 0 balance

        // Setup peer
        uint32 srcEid = 40161;
        address adapterAddress = makeAddr("adapter");
        bytes32 peer = bytes32(uint256(uint160(adapterAddress)));

        vm.prank(owner);
        oappReceiver.setPeer(srcEid, peer);

        // Build message
        uint256 nlpAmount = 100_000 * 1e18;
        NLPOAppJPYCReceiverV2.GiftMessage memory gift =
            NLPOAppJPYCReceiverV2.GiftMessage({recipient: recipient, amount: nlpAmount});

        bytes memory message = abi.encode(NLPOAppJPYCReceiverV2.MessageType.REQUEST, abi.encode(gift));

        // Fund receiver with native tokens for response
        vm.deal(address(oappReceiver), 1 ether);

        // Simulate receiving message
        Origin memory origin = Origin({srcEid: srcEid, sender: peer, nonce: 1});

        // Expect JPYCTransferFailed event
        vm.expectEmit(true, true, true, false);
        emit JPYCTransferFailed(recipient, nlpAmount, nlpAmount, "Insufficient JPYC balance");

        // Call lzReceive
        vm.prank(address(lzEndpoint));
        oappReceiver.lzReceive(origin, bytes32(0), message, address(0), bytes(""));

        // Verify recipient didn't receive JPYC
        assertEq(jpyc.balanceOf(recipient), 0);
    }

    /* ═══════════════════════════════════════════════════════════════════════
                            ADMIN FUNCTIONS TESTS
    ═══════════════════════════════════════════════════════════════════════ */

    function test_SetExchangeRate() public {
        uint256 newRate = 9500; // 0.95:1

        vm.prank(owner);
        oappReceiver.setExchangeRate(newRate);

        assertEq(oappReceiver.nlpToJpycRate(), newRate);
    }

    function test_GetExchangeQuote() public {
        uint256 nlpAmount = 100_000 * 1e18;
        uint256 expectedJpyc = nlpAmount; // 1:1 rate

        assertEq(oappReceiver.getExchangeQuote(nlpAmount), expectedJpyc);

        // Change rate to 0.9:1
        vm.prank(owner);
        oappReceiver.setExchangeRate(9000);

        expectedJpyc = (nlpAmount * 9000) / 10000;
        assertEq(oappReceiver.getExchangeQuote(nlpAmount), expectedJpyc);
    }
}

// Mock contracts for testing
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
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
}

contract MockLZEndpoint {
    mapping(address => address) public delegates;
    uint32 private _eid = 40161;

    function setDelegate(address) external {}

    function send(MessagingParams calldata, address) external payable returns (MessagingReceipt memory) {
        return MessagingReceipt({guid: bytes32(0), nonce: 1, fee: MessagingFee({nativeFee: 0, lzTokenFee: 0})});
    }

    function quote(MessagingParams calldata, address) external pure returns (MessagingFee memory) {
        return MessagingFee({nativeFee: 0.001 ether, lzTokenFee: 0});
    }

    function eid() external view returns (uint32) {
        return _eid;
    }
}

struct MessagingParams {
    uint32 dstEid;
    bytes32 receiver;
    bytes message;
    bytes options;
    bool payInLzToken;
}
