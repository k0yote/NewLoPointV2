// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test, console} from "forge-std/Test.sol";
import {NLPOAppAdapter} from "../src/NLPOAppAdapter.sol";
import {NLPOAppJPYCReceiver} from "../src/NLPOAppJPYCReceiver.sol";
import {NLPMinterBurner} from "../src/NLPMinterBurner.sol";
import {JPYCVault} from "../src/JPYCVault.sol";
import {Origin, MessagingReceipt, MessagingFee} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";

// Mock tokens
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => uint256) public nonces;

    bytes32 public DOMAIN_SEPARATOR;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;

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

    function burnFrom(address from, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        balanceOf[from] -= amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount);
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount);
        require(balanceOf[from] >= amount);

        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
    {
        require(block.timestamp <= deadline);
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

// Mock LZ Endpoint
contract MockLZEndpoint {
    mapping(address => address) public delegates;
    uint32 private _eid;

    constructor() {
        _eid = 30109; // Mock Polygon EID
    }

    function eid() external view returns (uint32) {
        return _eid;
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
 * @title IntegrationTest
 * @notice Integration test for full cross-chain flow
 * @dev Tests the complete Lock -> Request -> JPYC Transfer -> Response -> Burn/Unlock flow
 */
contract IntegrationTest is Test {
    // Contracts
    NLPOAppAdapter public adapter;
    NLPOAppJPYCReceiver public receiver;
    NLPMinterBurner public minterBurner;
    JPYCVault public vault;
    MockERC20 public nlpToken;
    MockERC20 public jpycToken;
    MockLZEndpoint public lzEndpoint;

    // Actors
    address public owner = address(this);
    address public user = address(0x1);
    uint32 public constant SONEIUM_EID = 1;
    uint32 public constant POLYGON_EID = 30109;

    function setUp() public {
        // Deploy tokens
        nlpToken = new MockERC20("NewLoPoint", "NLP");
        jpycToken = new MockERC20("JPY Coin", "JPYC");

        // Deploy LZ endpoint
        lzEndpoint = new MockLZEndpoint();

        // Deploy Soneium contracts
        minterBurner = new NLPMinterBurner(address(nlpToken), owner);
        adapter = new NLPOAppAdapter(address(nlpToken), address(minterBurner), address(lzEndpoint), owner);
        minterBurner.setOperator(address(adapter), true);

        // Deploy Polygon contracts
        vault = new JPYCVault(address(jpycToken), owner, 1000 ether);
        receiver = new NLPOAppJPYCReceiver(address(jpycToken), address(vault), address(lzEndpoint), owner);

        // Grant EXCHANGE_ROLE to receiver
        bytes32 EXCHANGE_ROLE = keccak256("EXCHANGE_ROLE");
        vault.grantRole(EXCHANGE_ROLE, address(receiver));

        // Grant MINTER_ROLE to minterBurner
        bytes32 MINTER_ROLE = keccak256("MINTER_ROLE");
        nlpToken.mint(address(minterBurner), 0); // Just to simulate granting role

        // Configure peers
        adapter.setPeer(POLYGON_EID, bytes32(uint256(uint160(address(receiver)))));
        receiver.setPeer(SONEIUM_EID, bytes32(uint256(uint160(address(adapter)))));

        // Setup: Fund vault with JPYC
        jpycToken.mint(address(this), 1000000 ether);
        jpycToken.approve(address(vault), 1000000 ether);
        vault.deposit(1000000 ether);

        // Fund receiver with native tokens for responses
        vm.deal(address(receiver), 10 ether);

        // Give user NLP
        nlpToken.mint(user, 1000 ether);

        // Give user ETH for fees
        vm.deal(user, 10 ether);
    }

    function testSuccessfulExchangeFlow() public {
        uint256 sendAmount = 100 ether;
        address recipient = user;

        console.log("=== Testing Successful Exchange Flow ===");
        console.log("User NLP balance before:", nlpToken.balanceOf(user));
        console.log("User JPYC balance before:", jpycToken.balanceOf(user));
        console.log("Vault JPYC balance:", jpycToken.balanceOf(address(vault)));

        // Step 1: User sends NLP via adapter
        vm.startPrank(user);
        nlpToken.approve(address(adapter), sendAmount);
        adapter.send{value: 0.01 ether}(POLYGON_EID, recipient, sendAmount, "");
        vm.stopPrank();

        console.log("\n--- After Send ---");
        console.log("User NLP balance:", nlpToken.balanceOf(user));
        console.log("Adapter NLP locked:", adapter.lockedBalances(user));
        console.log("Adapter NLP balance:", nlpToken.balanceOf(address(adapter)));

        // Verify lock
        assertEq(adapter.lockedBalances(user), sendAmount);
        assertEq(nlpToken.balanceOf(address(adapter)), sendAmount);
        assertEq(nlpToken.balanceOf(user), 900 ether);

        // Step 2: Simulate receiver processing (successful JPYC transfer)
        bytes memory requestMessage = abi.encode(
            NLPOAppAdapter.MessageType.REQUEST,
            abi.encode(NLPOAppAdapter.GiftMessage({recipient: recipient, amount: sendAmount}))
        );

        Origin memory origin =
            Origin({srcEid: SONEIUM_EID, sender: bytes32(uint256(uint160(address(adapter)))), nonce: 1});

        // Simulate _lzReceive on receiver
        vm.prank(address(lzEndpoint));
        receiver.lzReceive(origin, bytes32(0), requestMessage, address(0), "");

        console.log("\n--- After Receiver Processing ---");
        console.log("User JPYC balance:", jpycToken.balanceOf(user));

        // Verify JPYC was transferred
        assertEq(jpycToken.balanceOf(user), 100 ether);

        // Step 3: Simulate response back to adapter (success)
        bytes memory responseMessage = abi.encode(
            NLPOAppAdapter.MessageType.RESPONSE,
            abi.encode(NLPOAppAdapter.ResponseMessage({user: user, amount: sendAmount, success: true}))
        );

        Origin memory responseOrigin =
            Origin({srcEid: POLYGON_EID, sender: bytes32(uint256(uint160(address(receiver)))), nonce: 1});

        // Simulate _lzReceive on adapter
        vm.prank(address(lzEndpoint));
        adapter.lzReceive(responseOrigin, bytes32(0), responseMessage, address(0), "");

        console.log("\n--- After Response (Success) ---");
        console.log("User locked balance:", adapter.lockedBalances(user));
        console.log("Adapter NLP balance:", nlpToken.balanceOf(address(adapter)));

        // Verify burn occurred
        assertEq(adapter.lockedBalances(user), 0);
        assertEq(nlpToken.balanceOf(address(adapter)), 0); // Burned

        console.log("\n=== Test Complete: Success ===");
    }

    function test_FailedExchangeFlowWithUnlock() public {
        uint256 sendAmount = 100 ether;
        address recipient = user;

        console.log("=== Testing Failed Exchange Flow (Unlock) ===");

        // Step 1: User sends NLP
        vm.startPrank(user);
        nlpToken.approve(address(adapter), sendAmount);
        adapter.send{value: 0.01 ether}(POLYGON_EID, recipient, sendAmount, "");
        vm.stopPrank();

        // Verify lock
        assertEq(adapter.lockedBalances(user), sendAmount);

        // Step 2: Simulate response back to adapter (failure)
        bytes memory responseMessage = abi.encode(
            NLPOAppAdapter.MessageType.RESPONSE,
            abi.encode(
                NLPOAppAdapter.ResponseMessage({
                    user: user,
                    amount: sendAmount,
                    success: false // Failed!
                })
            )
        );

        Origin memory responseOrigin =
            Origin({srcEid: POLYGON_EID, sender: bytes32(uint256(uint160(address(receiver)))), nonce: 1});

        uint256 userBalanceBefore = nlpToken.balanceOf(user);

        // Simulate _lzReceive on adapter
        vm.prank(address(lzEndpoint));
        adapter.lzReceive(responseOrigin, bytes32(0), responseMessage, address(0), "");

        console.log("\n--- After Response (Failure) ---");
        console.log("User NLP balance:", nlpToken.balanceOf(user));
        console.log("User locked balance:", adapter.lockedBalances(user));

        // Verify unlock occurred
        assertEq(adapter.lockedBalances(user), 0);
        assertEq(nlpToken.balanceOf(user), userBalanceBefore + sendAmount); // Unlocked back to user
        assertEq(jpycToken.balanceOf(user), 0); // No JPYC received

        console.log("\n=== Test Complete: Unlock on Failure ===");
    }

    function testExchangeQuoteCalculation() public view {
        uint256 nlpAmount = 100 ether;

        uint256 adapterQuote = adapter.getExchangeQuote(nlpAmount);
        uint256 receiverQuote = receiver.getExchangeQuote(nlpAmount);

        // Both should match (same exchange rate)
        assertEq(adapterQuote, receiverQuote);
        assertEq(adapterQuote, 100 ether); // 1:1 default rate

        console.log("Exchange quote for 100 NLP:", adapterQuote / 1e18, "JPYC");
    }
}
