// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test, console} from "forge-std/Test.sol";
import {JPYCVault} from "../src/JPYCVault.sol";

/**
 * @title MockJPYC
 * @notice Mock JPYC token with EIP-2612 permit functionality for testing
 */
contract MockJPYC {
    string public name = "JPY Coin";
    string public symbol = "JPYC";
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => uint256) public nonces;

    bytes32 public DOMAIN_SEPARATOR;

    // EIP-2612 typehash
    bytes32 public constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Transfer(address indexed from, address indexed to, uint256 value);

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
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        require(balanceOf[from] >= amount, "Insufficient balance");

        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    /**
     * @notice EIP-2612 permit implementation
     */
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
    {
        require(block.timestamp <= deadline, "EIP2612: permit is expired");

        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonces[owner]++, deadline));

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));

        address signer = ecrecover(digest, v, r, s);
        require(signer == owner, "EIP2612: invalid signature");

        allowance[owner][spender] = value;
        emit Approval(owner, spender, value);
    }
}

/**
 * @title JPYCVaultTest
 * @notice Test suite for JPYCVault including depositWithPermit functionality
 */
contract JPYCVaultTest is Test {
    JPYCVault public vault;
    MockJPYC public jpyc;

    address public admin = makeAddr("admin");
    address public operator = makeAddr("operator");
    address public exchange = makeAddr("exchange");
    address public user = makeAddr("user");

    uint256 public constant INITIAL_JPYC = 1_000_000 * 1e18;
    uint256 public constant LOW_BALANCE_THRESHOLD = 100_000 * 1e18;

    // Permit signing
    uint256 public operatorPrivateKey;
    address public operatorAddress;

    event Deposited(address indexed operator, uint256 amount, uint256 newBalance);

    function setUp() public {
        // Setup accounts with private keys for permit signing
        operatorPrivateKey = 0xA11CE;
        operatorAddress = vm.addr(operatorPrivateKey);

        // Deploy mock JPYC
        jpyc = new MockJPYC();

        // Deploy vault
        vm.prank(admin);
        vault = new JPYCVault(address(jpyc), admin, LOW_BALANCE_THRESHOLD);

        // Grant roles
        vm.startPrank(admin);
        vault.grantRole(vault.OPERATOR_ROLE(), operator);
        vault.grantRole(vault.OPERATOR_ROLE(), operatorAddress);
        vault.grantRole(vault.EXCHANGE_ROLE(), exchange);
        vm.stopPrank();

        // Mint JPYC to operators
        jpyc.mint(operator, INITIAL_JPYC);
        jpyc.mint(operatorAddress, INITIAL_JPYC);
    }

    /* ═══════════════════════════════════════════════════════════════════════
                            REGULAR DEPOSIT TESTS
    ═══════════════════════════════════════════════════════════════════════ */

    function test_Deposit_Success() public {
        uint256 depositAmount = 100_000 * 1e18;

        // Approve vault
        vm.prank(operator);
        jpyc.approve(address(vault), depositAmount);

        // Deposit
        vm.prank(operator);
        vm.expectEmit(true, true, true, true);
        emit Deposited(operator, depositAmount, depositAmount);
        vault.deposit(depositAmount);

        // Verify
        assertEq(vault.balance(), depositAmount);
        assertEq(vault.totalDeposited(), depositAmount);
    }

    /* ═══════════════════════════════════════════════════════════════════════
                        DEPOSIT WITH PERMIT TESTS
    ═══════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test successful depositWithPermit
     */
    function test_DepositWithPermit_Success() public {
        uint256 depositAmount = 100_000 * 1e18;
        uint256 deadline = block.timestamp + 1 hours;

        // Get current nonce
        uint256 nonce = jpyc.nonces(operatorAddress);

        // Create permit signature
        bytes32 structHash = keccak256(
            abi.encode(jpyc.PERMIT_TYPEHASH(), operatorAddress, address(vault), depositAmount, nonce, deadline)
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", jpyc.DOMAIN_SEPARATOR(), structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPrivateKey, digest);

        // Deposit with permit (single transaction)
        vm.prank(operatorAddress);
        vm.expectEmit(true, true, true, true);
        emit Deposited(operatorAddress, depositAmount, depositAmount);
        vault.depositWithPermit(depositAmount, deadline, v, r, s);

        // Verify
        assertEq(vault.balance(), depositAmount);
        assertEq(vault.totalDeposited(), depositAmount);
        assertEq(jpyc.balanceOf(operatorAddress), INITIAL_JPYC - depositAmount);
        assertEq(jpyc.balanceOf(address(vault)), depositAmount);
    }

    /**
     * @notice Test depositWithPermit with expired deadline
     */
    function test_DepositWithPermit_ExpiredDeadline() public {
        uint256 depositAmount = 100_000 * 1e18;
        uint256 deadline = block.timestamp - 1; // Already expired

        // Get current nonce
        uint256 nonce = jpyc.nonces(operatorAddress);

        // Create permit signature
        bytes32 structHash = keccak256(
            abi.encode(jpyc.PERMIT_TYPEHASH(), operatorAddress, address(vault), depositAmount, nonce, deadline)
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", jpyc.DOMAIN_SEPARATOR(), structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPrivateKey, digest);

        // Should revert with expired deadline
        vm.prank(operatorAddress);
        vm.expectRevert("EIP2612: permit is expired");
        vault.depositWithPermit(depositAmount, deadline, v, r, s);
    }

    /**
     * @notice Test depositWithPermit with invalid signature
     */
    function test_DepositWithPermit_InvalidSignature() public {
        uint256 depositAmount = 100_000 * 1e18;
        uint256 deadline = block.timestamp + 1 hours;

        // Get current nonce
        uint256 nonce = jpyc.nonces(operatorAddress);

        // Create permit signature
        bytes32 structHash = keccak256(
            abi.encode(jpyc.PERMIT_TYPEHASH(), operatorAddress, address(vault), depositAmount, nonce, deadline)
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", jpyc.DOMAIN_SEPARATOR(), structHash));

        // Sign with WRONG private key
        uint256 wrongPrivateKey = 0xBAD;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPrivateKey, digest);

        // Should revert with invalid signature
        vm.prank(operatorAddress);
        vm.expectRevert("EIP2612: invalid signature");
        vault.depositWithPermit(depositAmount, deadline, v, r, s);
    }

    /**
     * @notice Test depositWithPermit with zero amount
     */
    function test_DepositWithPermit_ZeroAmount() public {
        uint256 depositAmount = 0;
        uint256 deadline = block.timestamp + 1 hours;

        // Get current nonce
        uint256 nonce = jpyc.nonces(operatorAddress);

        // Create permit signature
        bytes32 structHash = keccak256(
            abi.encode(jpyc.PERMIT_TYPEHASH(), operatorAddress, address(vault), depositAmount, nonce, deadline)
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", jpyc.DOMAIN_SEPARATOR(), structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPrivateKey, digest);

        // Should revert with ZeroAmount
        vm.prank(operatorAddress);
        vm.expectRevert(JPYCVault.ZeroAmount.selector);
        vault.depositWithPermit(depositAmount, deadline, v, r, s);
    }

    /**
     * @notice Test depositWithPermit without operator role
     */
    function test_DepositWithPermit_NotOperator() public {
        // Setup new user without OPERATOR_ROLE
        uint256 userPrivateKey = 0xBABE;
        address userAddr = vm.addr(userPrivateKey);
        jpyc.mint(userAddr, INITIAL_JPYC);

        uint256 depositAmount = 100_000 * 1e18;
        uint256 deadline = block.timestamp + 1 hours;

        // Get current nonce
        uint256 nonce = jpyc.nonces(userAddr);

        // Create permit signature
        bytes32 structHash =
            keccak256(abi.encode(jpyc.PERMIT_TYPEHASH(), userAddr, address(vault), depositAmount, nonce, deadline));

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", jpyc.DOMAIN_SEPARATOR(), structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, digest);

        // Should revert - not authorized
        vm.prank(userAddr);
        vm.expectRevert();
        vault.depositWithPermit(depositAmount, deadline, v, r, s);
    }

    /**
     * @notice Test depositWithPermit when paused
     */
    function test_DepositWithPermit_WhenPaused() public {
        uint256 depositAmount = 100_000 * 1e18;
        uint256 deadline = block.timestamp + 1 hours;

        // Pause vault
        vm.prank(admin);
        vault.pause();

        // Get current nonce
        uint256 nonce = jpyc.nonces(operatorAddress);

        // Create permit signature
        bytes32 structHash = keccak256(
            abi.encode(jpyc.PERMIT_TYPEHASH(), operatorAddress, address(vault), depositAmount, nonce, deadline)
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", jpyc.DOMAIN_SEPARATOR(), structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPrivateKey, digest);

        // Should revert - paused
        vm.prank(operatorAddress);
        vm.expectRevert();
        vault.depositWithPermit(depositAmount, deadline, v, r, s);
    }

    /**
     * @notice Test multiple depositWithPermit calls (nonce increment)
     */
    function test_DepositWithPermit_MultipleDeposits() public {
        uint256 depositAmount = 50_000 * 1e18;
        uint256 deadline = block.timestamp + 1 hours;

        // First deposit
        {
            uint256 nonce = jpyc.nonces(operatorAddress);
            bytes32 structHash = keccak256(
                abi.encode(jpyc.PERMIT_TYPEHASH(), operatorAddress, address(vault), depositAmount, nonce, deadline)
            );
            bytes32 digest = keccak256(abi.encodePacked("\x19\x01", jpyc.DOMAIN_SEPARATOR(), structHash));
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPrivateKey, digest);

            vm.prank(operatorAddress);
            vault.depositWithPermit(depositAmount, deadline, v, r, s);
        }

        // Second deposit (nonce should have incremented)
        {
            uint256 nonce = jpyc.nonces(operatorAddress);
            bytes32 structHash = keccak256(
                abi.encode(jpyc.PERMIT_TYPEHASH(), operatorAddress, address(vault), depositAmount, nonce, deadline)
            );
            bytes32 digest = keccak256(abi.encodePacked("\x19\x01", jpyc.DOMAIN_SEPARATOR(), structHash));
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPrivateKey, digest);

            vm.prank(operatorAddress);
            vault.depositWithPermit(depositAmount, deadline, v, r, s);
        }

        // Verify both deposits succeeded
        assertEq(vault.balance(), depositAmount * 2);
        assertEq(vault.totalDeposited(), depositAmount * 2);
        assertEq(jpyc.nonces(operatorAddress), 2); // Nonce should be 2
    }

    /* ═══════════════════════════════════════════════════════════════════════
                        COMPARISON: DEPOSIT vs DEPOSIT WITH PERMIT
    ═══════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Gas comparison between deposit and depositWithPermit
     */
    function test_GasComparison() public {
        uint256 depositAmount = 100_000 * 1e18;

        // Regular deposit (2 transactions)
        vm.prank(operator);
        jpyc.approve(address(vault), depositAmount);

        uint256 gasStart = gasleft();
        vm.prank(operator);
        vault.deposit(depositAmount);
        uint256 regularGas = gasStart - gasleft();

        console.log("Regular deposit gas:", regularGas);

        // Deposit with permit (1 transaction)
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = jpyc.nonces(operatorAddress);

        bytes32 structHash = keccak256(
            abi.encode(jpyc.PERMIT_TYPEHASH(), operatorAddress, address(vault), depositAmount, nonce, deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", jpyc.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPrivateKey, digest);

        gasStart = gasleft();
        vm.prank(operatorAddress);
        vault.depositWithPermit(depositAmount, deadline, v, r, s);
        uint256 permitGas = gasStart - gasleft();

        console.log("Deposit with permit gas:", permitGas);
        console.log("Note: Permit saves one transaction (approval), which saves ~46k gas");
    }
}
