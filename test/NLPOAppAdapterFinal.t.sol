// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test, console} from "forge-std/Test.sol";
import {NLPOAppAdapterFinal} from "../src/NLPOAppAdapter_Final.sol";
import {Origin} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";

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

    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8, bytes32, bytes32) external {
        require(block.timestamp <= deadline, "Permit expired");
        allowance[owner][spender] = value;
        nonces[owner]++;
    }
}

contract MockMinterBurner {
    MockNLPToken public nlpToken;

    constructor(address _nlpToken) {
        nlpToken = MockNLPToken(_nlpToken);
    }

    function burn(address from, uint256 amount) external {
        nlpToken.burn(from, amount);
    }
}

contract MockLZEndpoint {
    uint32 public constant EID = 30184; // Mock EID
    mapping(address => address) public delegates;
    bool public shouldFailSend;

    function eid() external pure returns (uint32) {
        return EID;
    }

    function setDelegate(address _delegate) external {
        delegates[msg.sender] = _delegate;
    }

    function setShouldFailSend(bool _shouldFail) external {
        shouldFailSend = _shouldFail;
    }

    function send(uint32, bytes memory, bytes memory, address) external payable returns (bytes32, uint64, uint256) {
        require(!shouldFailSend, "Send failed");
        return (bytes32(uint256(1)), 1, msg.value);
    }

    function quote(uint32, bytes memory, bytes memory, bool) external pure returns (uint256, uint256) {
        return (0.01 ether, 0);
    }
}

/**
 * @title NLPOAppAdapterFinalTest
 * @notice Test suite for NLPOAppAdapterFinal contract with fee logic and improved burn/unlock
 */
contract NLPOAppAdapterFinalTest is Test {
    NLPOAppAdapterFinal public adapter;
    MockMinterBurner public minterBurner;
    MockNLPToken public nlpToken;
    MockLZEndpoint public lzEndpoint;

    address public owner = address(this);
    address public user = address(0x1);
    address public recipient = address(0x2);

    uint32 public constant POLYGON_EID = 30109;

    // Events to test
    event NLPLocked(address indexed user, uint256 amount, uint32 dstEid);
    event NLPBurned(address indexed user, uint256 amount);
    event NLPUnlocked(address indexed user, uint256 amount);
    event ExchangeFeeUpdated(uint256 oldFee, uint256 newFee);
    event OperationalFeeUpdated(uint256 oldFee, uint256 newFee);

    function setUp() public {
        // Deploy mocks
        nlpToken = new MockNLPToken();
        lzEndpoint = new MockLZEndpoint();
        minterBurner = new MockMinterBurner(address(nlpToken));

        // Deploy adapter
        adapter = new NLPOAppAdapterFinal(address(nlpToken), address(minterBurner), address(lzEndpoint), owner);

        // Configure peer
        adapter.setPeer(POLYGON_EID, bytes32(uint256(uint160(recipient))));

        // Mint tokens to user
        nlpToken.mint(user, 10000 ether);
    }

    /* ═══════════════════════════════════════════════════════════════════════
                        FEE LOGIC TESTS
    ═══════════════════════════════════════════════════════════════════════ */

    function testGetExchangeQuote_NoFees() public view {
        uint256 nlpAmount = 1000 ether;

        (uint256 gross, uint256 exFee, uint256 opFee, uint256 net) =
            adapter.getExchangeQuote(NLPOAppAdapterFinal.TokenType.JPYC, nlpAmount);

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
            adapter.getExchangeQuote(NLPOAppAdapterFinal.TokenType.JPYC, nlpAmount);

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
            adapter.getExchangeQuote(NLPOAppAdapterFinal.TokenType.JPYC, nlpAmount);

        assertEq(gross, 1000 ether, "Gross should be 1000");
        assertEq(exFee, 10 ether, "Exchange fee should be 10");
        assertEq(opFee, 5 ether, "Operational fee should be 5");
        assertEq(net, 985 ether, "Net should be 985");
    }

    function testSetExchangeFee_Success() public {
        vm.expectEmit(true, true, true, true);
        emit ExchangeFeeUpdated(0, 100);

        adapter.setExchangeFee(100);
        assertEq(adapter.exchangeFee(), 100, "Exchange fee should be updated");
    }

    function testSetExchangeFee_ExceedsMax() public {
        vm.expectRevert(abi.encodeWithSelector(NLPOAppAdapterFinal.InvalidFeeRate.selector, 501, 500));
        adapter.setExchangeFee(501); // MAX_FEE is 500
    }

    function testSetOperationalFee_Success() public {
        vm.expectEmit(true, true, true, true);
        emit OperationalFeeUpdated(0, 50);

        adapter.setOperationalFee(50);
        assertEq(adapter.operationalFee(), 50, "Operational fee should be updated");
    }

    function testSetOperationalFee_ExceedsMax() public {
        vm.expectRevert(abi.encodeWithSelector(NLPOAppAdapterFinal.InvalidFeeRate.selector, 600, 500));
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

    /* ═══════════════════════════════════════════════════════════════════════
                        BURN/UNLOCK TESTS
    ═══════════════════════════════════════════════════════════════════════ */

    function testLzReceive_Success_BurnsNLP() public {
        // Setup: Lock tokens first
        vm.startPrank(user);
        nlpToken.approve(address(adapter), 1000 ether);
        vm.stopPrank();

        // Manually set locked balance for testing
        vm.store(
            address(adapter),
            keccak256(abi.encode(user, 3)), // lockedBalances slot
            bytes32(uint256(1000 ether))
        );

        uint256 userBalanceBefore = nlpToken.balanceOf(user);
        uint256 adapterBalanceBefore = 1000 ether;

        // Simulate successful response from receiver
        bytes memory responseData =
            abi.encode(NLPOAppAdapterFinal.ResponseMessage({user: user, amount: 1000 ether, success: true}));

        bytes memory message = abi.encode(
            uint16(2), // SEND_RESPONSE
            responseData,
            uint256(0), // extraOptionsLength
            bytes(""), // extraOptions
            uint256(0)
        );

        Origin memory origin = Origin({srcEid: POLYGON_EID, sender: bytes32(uint256(uint160(recipient))), nonce: 1});

        // Mint tokens to adapter to simulate locked state
        nlpToken.mint(address(adapter), 1000 ether);

        vm.expectEmit(true, true, true, true);
        emit NLPBurned(user, 1000 ether);

        // Call lzReceive
        vm.prank(address(lzEndpoint));
        adapter.lzReceive(origin, bytes32(0), message, address(0), bytes(""));

        // Verify tokens were burned (balance reduced)
        assertEq(nlpToken.balanceOf(address(adapter)), 0, "Adapter balance should be 0 after burn");
        assertEq(adapter.lockedBalances(user), 0, "Locked balance should be 0");
    }

    function testLzReceive_Failure_UnlocksNLP() public {
        // Setup: Lock tokens
        vm.store(address(adapter), keccak256(abi.encode(user, 3)), bytes32(uint256(1000 ether)));

        // Mint tokens to adapter
        nlpToken.mint(address(adapter), 1000 ether);

        uint256 userBalanceBefore = nlpToken.balanceOf(user);

        // Simulate failed response
        bytes memory responseData =
            abi.encode(NLPOAppAdapterFinal.ResponseMessage({user: user, amount: 1000 ether, success: false}));

        bytes memory message = abi.encode(
            uint16(2), // SEND_RESPONSE
            responseData,
            uint256(0),
            bytes(""),
            uint256(0)
        );

        Origin memory origin = Origin({srcEid: POLYGON_EID, sender: bytes32(uint256(uint160(recipient))), nonce: 1});

        vm.expectEmit(true, true, true, true);
        emit NLPUnlocked(user, 1000 ether);

        // Call lzReceive
        vm.prank(address(lzEndpoint));
        adapter.lzReceive(origin, bytes32(0), message, address(0), bytes(""));

        // Verify tokens were unlocked to user
        assertEq(nlpToken.balanceOf(user), userBalanceBefore + 1000 ether, "User should receive unlocked tokens");
        assertEq(nlpToken.balanceOf(address(adapter)), 0, "Adapter balance should be 0");
        assertEq(adapter.lockedBalances(user), 0, "Locked balance should be 0");
    }

    function testLzReceive_RevertOnInvalidAmount() public {
        bytes memory responseData = abi.encode(
            NLPOAppAdapterFinal.ResponseMessage({
                user: user,
                amount: 0, // Invalid amount
                success: true
            })
        );

        bytes memory message = abi.encode(uint16(2), responseData, uint256(0), bytes(""), uint256(0));

        Origin memory origin = Origin({srcEid: POLYGON_EID, sender: bytes32(uint256(uint160(recipient))), nonce: 1});

        vm.expectRevert(NLPOAppAdapterFinal.InvalidAmount.selector);
        vm.prank(address(lzEndpoint));
        adapter.lzReceive(origin, bytes32(0), message, address(0), bytes(""));
    }

    function testLzReceive_RevertOnNoLockedTokens() public {
        bytes memory responseData =
            abi.encode(NLPOAppAdapterFinal.ResponseMessage({user: user, amount: 1000 ether, success: true}));

        bytes memory message = abi.encode(uint16(2), responseData, uint256(0), bytes(""), uint256(0));

        Origin memory origin = Origin({srcEid: POLYGON_EID, sender: bytes32(uint256(uint160(recipient))), nonce: 1});

        vm.expectRevert(NLPOAppAdapterFinal.NoLockedTokens.selector);
        vm.prank(address(lzEndpoint));
        adapter.lzReceive(origin, bytes32(0), message, address(0), bytes(""));
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
            adapter.getExchangeQuote(NLPOAppAdapterFinal.TokenType.JPYC, 1000 ether);

        // Verify quote calculation
        assertEq(gross, 1000 ether);
        assertEq(exFee, 10 ether);
        assertEq(opFee, 5 ether);
        assertEq(net, 985 ether);
    }

    function testExchangeRateChange_AffectsQuote() public {
        uint256 nlpAmount = 1000 ether;

        // Initial rate (1:1)
        (uint256 gross1,,,) = adapter.getExchangeQuote(NLPOAppAdapterFinal.TokenType.JPYC, nlpAmount);
        assertEq(gross1, 1000 ether);

        // Change rate to 0.9:1
        adapter.setExchangeRate(9000);

        (uint256 gross2,,,) = adapter.getExchangeQuote(NLPOAppAdapterFinal.TokenType.JPYC, nlpAmount);
        assertEq(gross2, 900 ether);
    }
}
