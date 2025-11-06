// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title JPYCVault
 * @author NewLo Team
 * @notice Vault contract for managing JPYC liquidity for NLP exchanges
 * @dev Centralized JPYC liquidity management with access control
 *
 * Key Features:
 * - Centralized JPYC liquidity for multiple exchanges
 * - Role-based access control for deposits and withdrawals
 * - Emergency pause functionality
 * - Monitoring and alerting hooks
 * - Audit trail via events
 *
 * Roles:
 * - DEFAULT_ADMIN_ROLE: Super admin, can grant/revoke roles
 * - OPERATOR_ROLE: Can deposit JPYC into vault
 * - EXCHANGE_ROLE: Authorized exchanges that can withdraw JPYC
 * - EMERGENCY_ROLE: Can pause/unpause in emergencies
 *
 * Usage:
 * 1. Operator buys JPYC from market
 * 2. Operator deposits JPYC into vault via deposit()
 * 3. Exchanges withdraw JPYC when users exchange NLP
 * 4. Monitoring system alerts when balance is low
 */
contract JPYCVault is AccessControl, Pausable {
    using SafeERC20 for IERC20;

    /* ═══════════════════════════════════════════════════════════════════════
                                    ROLES
    ═══════════════════════════════════════════════════════════════════════ */

    /// @notice Role for operators who can deposit JPYC
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    /// @notice Role for authorized exchanges that can withdraw JPYC
    bytes32 public constant EXCHANGE_ROLE = keccak256("EXCHANGE_ROLE");

    /// @notice Role for emergency managers who can pause/unpause
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    /* ═══════════════════════════════════════════════════════════════════════
                               IMMUTABLE STATE
    ═══════════════════════════════════════════════════════════════════════ */

    /// @notice JPYC token contract
    IERC20 public immutable jpyc;

    /* ═══════════════════════════════════════════════════════════════════════
                              MUTABLE STATE
    ═══════════════════════════════════════════════════════════════════════ */

    /// @notice Low balance threshold for monitoring alerts (in JPYC wei)
    uint256 public lowBalanceThreshold;

    /// @notice Total JPYC deposited (for statistics)
    uint256 public totalDeposited;

    /// @notice Total JPYC withdrawn (for statistics)
    uint256 public totalWithdrawn;

    /// @notice Withdrawn amount per exchange
    mapping(address => uint256) public exchangeWithdrawals;

    /* ═══════════════════════════════════════════════════════════════════════
                                   EVENTS
    ═══════════════════════════════════════════════════════════════════════ */

    /// @notice Emitted when JPYC is deposited
    event Deposited(address indexed operator, uint256 amount, uint256 newBalance);

    /// @notice Emitted when JPYC is withdrawn by an exchange
    event Withdrawn(address indexed exchange, address indexed recipient, uint256 amount, uint256 newBalance);

    /// @notice Emitted when low balance threshold is reached
    event LowBalanceAlert(uint256 currentBalance, uint256 threshold);

    /// @notice Emitted when threshold is updated
    event ThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);

    /// @notice Emitted when emergency withdrawal is performed
    event EmergencyWithdrawal(address indexed to, uint256 amount);

    /// @notice Emitted when vault is deployed
    event VaultDeployed(address indexed jpyc, address indexed admin, uint256 chainId);

    /* ═══════════════════════════════════════════════════════════════════════
                                   ERRORS
    ═══════════════════════════════════════════════════════════════════════ */

    error InsufficientBalance(uint256 requested, uint256 available);
    error ZeroAmount();
    error ZeroAddress();
    error NotAuthorizedExchange();

    /* ═══════════════════════════════════════════════════════════════════════
                                 CONSTRUCTOR
    ═══════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Initialize the JPYCVault
     * @param _jpyc Address of JPYC token contract
     * @param _admin Address that will have admin role
     * @param _lowBalanceThreshold Initial threshold for low balance alerts
     *
     * @dev Admin should be a secure multisig
     */
    constructor(address _jpyc, address _admin, uint256 _lowBalanceThreshold) {
        if (_jpyc == address(0)) revert ZeroAddress();
        if (_admin == address(0)) revert ZeroAddress();

        jpyc = IERC20(_jpyc);
        lowBalanceThreshold = _lowBalanceThreshold;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _admin);
        _grantRole(EMERGENCY_ROLE, _admin);

        emit VaultDeployed(_jpyc, _admin, block.chainid);
    }

    /* ═══════════════════════════════════════════════════════════════════════
                            OPERATOR FUNCTIONS
    ═══════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Deposit JPYC into vault
     * @param amount Amount of JPYC to deposit
     *
     * @dev Operator must approve this contract to spend JPYC first
     * @dev Only OPERATOR_ROLE can call this function
     *
     * Usage:
     * ```
     * // 1. Operator approves vault
     * await jpyc.approve(vaultAddress, amount);
     *
     * // 2. Operator deposits
     * await vault.deposit(amount);
     * ```
     */
    function deposit(uint256 amount) external onlyRole(OPERATOR_ROLE) whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        // Transfer JPYC from operator to vault
        jpyc.safeTransferFrom(msg.sender, address(this), amount);

        // Update statistics
        totalDeposited += amount;

        uint256 newBalance = jpyc.balanceOf(address(this));

        emit Deposited(msg.sender, amount, newBalance);
    }

    /* ═══════════════════════════════════════════════════════════════════════
                            EXCHANGE FUNCTIONS
    ═══════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Withdraw JPYC to a recipient (called by authorized exchanges)
     * @param recipient Address to receive JPYC
     * @param amount Amount of JPYC to withdraw
     *
     * @dev Only EXCHANGE_ROLE can call this function
     * @dev Reverts if insufficient balance
     * @dev Emits LowBalanceAlert if balance drops below threshold
     *
     * Usage (from exchange contract):
     * ```
     * function exchange(uint256 nlpAmount, uint256 minJpyc) external {
     *   // ... NLP processing ...
     *
     *   // Withdraw JPYC from vault
     *   vault.withdraw(msg.sender, jpycAmount);
     * }
     * ```
     */
    function withdraw(address recipient, uint256 amount) external onlyRole(EXCHANGE_ROLE) whenNotPaused {
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        uint256 currentBalance = jpyc.balanceOf(address(this));
        if (currentBalance < amount) {
            revert InsufficientBalance(amount, currentBalance);
        }

        // Update statistics
        totalWithdrawn += amount;
        exchangeWithdrawals[msg.sender] += amount;

        // Transfer JPYC to recipient
        jpyc.safeTransfer(recipient, amount);

        uint256 newBalance = currentBalance - amount;

        emit Withdrawn(msg.sender, recipient, amount, newBalance);

        // Check if balance is below threshold
        if (newBalance < lowBalanceThreshold && lowBalanceThreshold > 0) {
            emit LowBalanceAlert(newBalance, lowBalanceThreshold);
        }
    }

    /* ═══════════════════════════════════════════════════════════════════════
                            VIEW FUNCTIONS
    ═══════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Get current JPYC balance in vault
     * @return uint256 JPYC balance
     */
    function balance() external view returns (uint256) {
        return jpyc.balanceOf(address(this));
    }

    /**
     * @notice Check if vault has sufficient liquidity
     * @param amount Amount to check
     * @return bool True if sufficient balance
     */
    function hasSufficientLiquidity(uint256 amount) external view returns (bool) {
        return jpyc.balanceOf(address(this)) >= amount;
    }

    /**
     * @notice Check if current balance is below threshold
     * @return bool True if balance is low
     */
    function isBalanceLow() external view returns (bool) {
        if (lowBalanceThreshold == 0) return false;
        return jpyc.balanceOf(address(this)) < lowBalanceThreshold;
    }

    /**
     * @notice Get statistics for an exchange
     * @param exchange Address of exchange
     * @return withdrawn Total amount withdrawn by this exchange
     */
    function getExchangeStats(address exchange) external view returns (uint256 withdrawn) {
        return exchangeWithdrawals[exchange];
    }

    /* ═══════════════════════════════════════════════════════════════════════
                            ADMIN FUNCTIONS
    ═══════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Update low balance threshold
     * @param newThreshold New threshold value
     *
     * @dev Only DEFAULT_ADMIN_ROLE can call
     */
    function updateThreshold(uint256 newThreshold) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 oldThreshold = lowBalanceThreshold;
        lowBalanceThreshold = newThreshold;
        emit ThresholdUpdated(oldThreshold, newThreshold);
    }

    /**
     * @notice Pause the vault (emergency only)
     * @dev Only EMERGENCY_ROLE can call
     * @dev Prevents deposits and withdrawals
     */
    function pause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause the vault
     * @dev Only EMERGENCY_ROLE can call
     */
    function unpause() external onlyRole(EMERGENCY_ROLE) {
        _unpause();
    }

    /**
     * @notice Emergency withdrawal of all JPYC (when paused)
     * @param to Address to receive JPYC
     *
     * @dev Only DEFAULT_ADMIN_ROLE can call
     * @dev Can only be called when paused
     * @dev Used for migrating to new vault or emergency situations
     */
    function emergencyWithdraw(address to) external onlyRole(DEFAULT_ADMIN_ROLE) whenPaused {
        if (to == address(0)) revert ZeroAddress();

        uint256 amount = jpyc.balanceOf(address(this));
        if (amount == 0) revert ZeroAmount();

        jpyc.safeTransfer(to, amount);

        emit EmergencyWithdrawal(to, amount);
    }

    /* ═══════════════════════════════════════════════════════════════════════
                            CONVENIENCE FUNCTIONS
    ═══════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Grant EXCHANGE_ROLE to an address
     * @param exchange Address of exchange contract
     *
     * @dev Convenience function for admin
     */
    function authorizeExchange(address exchange) external onlyRole(DEFAULT_ADMIN_ROLE) {
        grantRole(EXCHANGE_ROLE, exchange);
    }

    /**
     * @notice Revoke EXCHANGE_ROLE from an address
     * @param exchange Address of exchange contract
     *
     * @dev Convenience function for admin
     */
    function deauthorizeExchange(address exchange) external onlyRole(DEFAULT_ADMIN_ROLE) {
        revokeRole(EXCHANGE_ROLE, exchange);
    }

    /**
     * @notice Grant OPERATOR_ROLE to an address
     * @param operator Address of operator
     *
     * @dev Convenience function for admin
     */
    function authorizeOperator(address operator) external onlyRole(DEFAULT_ADMIN_ROLE) {
        grantRole(OPERATOR_ROLE, operator);
    }

    /**
     * @notice Revoke OPERATOR_ROLE from an address
     * @param operator Address of operator
     *
     * @dev Convenience function for admin
     */
    function deauthorizeOperator(address operator) external onlyRole(DEFAULT_ADMIN_ROLE) {
        revokeRole(OPERATOR_ROLE, operator);
    }
}
