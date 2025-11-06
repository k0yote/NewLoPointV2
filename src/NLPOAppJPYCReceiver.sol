// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {OApp, Origin, MessagingFee, MessagingReceipt} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IJPYCVault {
    function withdraw(address to, uint256 amount) external returns (bool);
    function balance() external view returns (uint256);
}

/**
 * @title NLPOAppJPYCReceiver
 * @author NewLo Team
 * @notice LayerZero OApp receiver for handling JPYC exchange requests
 * @dev Receives requests from source chain, attempts JPYC transfer, sends result back
 *
 * Key Features:
 * - Receives GiftMessage from source chain
 * - Attempts to transfer JPYC from vault to recipient
 * - Sends ResponseMessage back to source chain with success/failure status
 * - Automatic failure recovery on source chain
 * - Provides exchange rate quotes for NLP to JPYC
 *
 * Message Flow:
 * 1. Receive GiftMessage from Chain A
 * 2. Calculate JPYC amount based on exchange rate
 * 3. Attempt JPYC withdrawal from vault
 * 4. Send ResponseMessage back to Chain A
 *    - success=true: Chain A burns NLP
 *    - success=false: Chain A unlocks NLP back to user
 */
contract NLPOAppJPYCReceiver is OApp, ReentrancyGuard {
    using OptionsBuilder for bytes;
    using SafeERC20 for IERC20;

    /* ═══════════════════════════════════════════════════════════════════════
                                   STRUCTS
    ═══════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Message type identifier
     */
    enum MessageType {
        REQUEST, // Chain A -> Chain B: Request JPYC exchange
        RESPONSE // Chain B -> Chain A: Result of JPYC exchange
    }

    /**
     * @notice Request message for JPYC exchange
     * @param recipient Address to receive JPYC on destination chain
     * @param amount Amount of NLP tokens locked on source chain
     */
    struct GiftMessage {
        address recipient;
        uint256 amount;
    }

    /**
     * @notice Response message to source chain
     * @param user Original user who requested exchange
     * @param amount Amount of NLP that was locked
     * @param success Whether JPYC transfer succeeded
     */
    struct ResponseMessage {
        address user;
        uint256 amount;
        bool success;
    }

    /* ═══════════════════════════════════════════════════════════════════════
                                   EVENTS
    ═══════════════════════════════════════════════════════════════════════ */

    /// @notice Emitted when JPYC is successfully transferred
    event JPYCTransferred(address indexed recipient, uint256 jpycAmount, uint256 nlpAmount);

    /// @notice Emitted when JPYC transfer fails
    event JPYCTransferFailed(address indexed recipient, uint256 jpycAmount, uint256 nlpAmount);

    /// @notice Emitted when response is sent back to source chain
    event ResponseSent(address indexed user, uint256 amount, bool success, uint32 indexed srcEid);

    /// @notice Emitted when exchange rate is updated
    event ExchangeRateUpdated(uint256 oldRate, uint256 newRate);

    /// @notice Emitted when vault is updated
    event VaultUpdated(address indexed oldVault, address indexed newVault);

    /// @notice Emitted when gas limit is updated
    event GasLimitUpdated(uint256 oldLimit, uint256 newLimit);

    /* ═══════════════════════════════════════════════════════════════════════
                                   ERRORS
    ═══════════════════════════════════════════════════════════════════════ */

    error InvalidAmount();
    error InvalidAddress();
    error InsufficientVaultBalance();
    error InsufficientFee();

    /* ═══════════════════════════════════════════════════════════════════════
                               IMMUTABLE STATE
    ═══════════════════════════════════════════════════════════════════════ */

    /// @notice JPYC token
    IERC20 public immutable jpycToken;

    /* ═══════════════════════════════════════════════════════════════════════
                              MUTABLE STATE
    ═══════════════════════════════════════════════════════════════════════ */

    /// @notice JPYCVault for liquidity
    IJPYCVault public jpycVault;

    /// @notice Exchange rate from NLP to JPYC (denominator: 10000)
    /// @dev 10000 = 1:1, 9000 = 0.9:1, etc.
    uint256 public nlpToJpycRate = 10000;

    /// @notice Rate denominator for precision
    uint256 public constant RATE_DENOMINATOR = 10000;

    /// @notice Gas limit for response message to source chain
    uint128 public gasLimit = 200_000;

    /* ═══════════════════════════════════════════════════════════════════════
                                 CONSTRUCTOR
    ═══════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Initialize the NLPOAppJPYCReceiver
     * @param _jpycToken Address of JPYC token
     * @param _jpycVault Address of JPYCVault
     * @param _endpoint Address of LayerZero Endpoint V2 on destination chain
     * @param _owner Address that will have owner privileges
     */
    constructor(address _jpycToken, address _jpycVault, address _endpoint, address _owner)
        OApp(_endpoint, _owner)
        Ownable(_owner)
    {
        if (_jpycToken == address(0)) revert InvalidAddress();
        if (_jpycVault == address(0)) revert InvalidAddress();

        jpycToken = IERC20(_jpycToken);
        jpycVault = IJPYCVault(_jpycVault);
    }

    /* ═══════════════════════════════════════════════════════════════════════
                            RECEIVE FUNCTIONS
    ═══════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Receive request from source chain and process JPYC exchange
     * @param _origin Origin information (source chain and sender)
     * @param _guid Global unique identifier
     * @param _message Encoded message
     * @param _executor Executor address
     * @param _extraData Extra data from executor
     */
    function _lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) internal override nonReentrant {
        // Decode message type
        (MessageType msgType, bytes memory data) = abi.decode(_message, (MessageType, bytes));

        // Only process REQUEST messages
        if (msgType != MessageType.REQUEST) revert("Invalid message type");

        // Decode gift message
        GiftMessage memory gift = abi.decode(data, (GiftMessage));

        if (gift.amount == 0) revert InvalidAmount();
        if (gift.recipient == address(0)) revert InvalidAddress();

        // Calculate JPYC amount
        uint256 jpycAmount = (gift.amount * nlpToJpycRate) / RATE_DENOMINATOR;

        bool success = false;

        // Check vault has sufficient balance
        if (jpycVault.balance() >= jpycAmount) {
            // Attempt JPYC withdrawal from vault
            try jpycVault.withdraw(gift.recipient, jpycAmount) returns (bool result) {
                success = result;
                if (success) {
                    emit JPYCTransferred(gift.recipient, jpycAmount, gift.amount);
                } else {
                    emit JPYCTransferFailed(gift.recipient, jpycAmount, gift.amount);
                }
            } catch {
                emit JPYCTransferFailed(gift.recipient, jpycAmount, gift.amount);
            }
        } else {
            emit JPYCTransferFailed(gift.recipient, jpycAmount, gift.amount);
        }

        // Send response back to source chain
        _sendResponse(_origin.srcEid, gift.recipient, gift.amount, success);
    }

    /* ═══════════════════════════════════════════════════════════════════════
                            INTERNAL FUNCTIONS
    ═══════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Send response message back to source chain
     * @param _srcEid Source endpoint ID
     * @param _user User address
     * @param _amount NLP amount
     * @param _success Whether JPYC transfer succeeded
     */
    function _sendResponse(uint32 _srcEid, address _user, uint256 _amount, bool _success) internal {
        // Build response message
        bytes memory message =
            abi.encode(MessageType.RESPONSE, ResponseMessage({user: _user, amount: _amount, success: _success}));

        bytes memory options = _buildOptions();

        // Quote fee (we need to fund this contract with native tokens)
        MessagingFee memory fee = _quote(_srcEid, message, options, false);

        // Check contract has enough native tokens
        if (address(this).balance < fee.nativeFee) revert InsufficientFee();

        // Send response
        _lzSend(_srcEid, message, options, MessagingFee(fee.nativeFee, 0), payable(address(this)));

        emit ResponseSent(_user, _amount, _success, _srcEid);
    }

    /**
     * @notice Build default options for message execution
     * @return options Encoded options
     */
    function _buildOptions() internal view returns (bytes memory) {
        return OptionsBuilder.newOptions().addExecutorLzReceiveOption(gasLimit, 0);
    }

    /* ═══════════════════════════════════════════════════════════════════════
                            QUOTE FUNCTIONS
    ═══════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Get exchange quote for NLP to JPYC
     * @param nlpAmount Amount of NLP tokens
     * @return jpycAmount Estimated JPYC amount user would receive
     */
    function getExchangeQuote(uint256 nlpAmount) external view returns (uint256 jpycAmount) {
        if (nlpAmount == 0) return 0;
        jpycAmount = (nlpAmount * nlpToJpycRate) / RATE_DENOMINATOR;
        return jpycAmount;
    }

    /* ═══════════════════════════════════════════════════════════════════════
                            ADMIN FUNCTIONS
    ═══════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Update exchange rate
     * @param _newRate New rate (denominator: 10000)
     */
    function setExchangeRate(uint256 _newRate) external onlyOwner {
        uint256 oldRate = nlpToJpycRate;
        nlpToJpycRate = _newRate;
        emit ExchangeRateUpdated(oldRate, _newRate);
    }

    /**
     * @notice Update JPYC vault
     * @param _newVault New vault address
     */
    function setJPYCVault(address _newVault) external onlyOwner {
        if (_newVault == address(0)) revert InvalidAddress();
        address oldVault = address(jpycVault);
        jpycVault = IJPYCVault(_newVault);
        emit VaultUpdated(oldVault, _newVault);
    }

    /**
     * @notice Update gas limit for response messages
     * @param _newLimit New gas limit
     */
    function setGasLimit(uint128 _newLimit) external onlyOwner {
        uint256 oldLimit = gasLimit;
        gasLimit = _newLimit;
        emit GasLimitUpdated(oldLimit, _newLimit);
    }

    /**
     * @notice Fund contract with native tokens for response messages
     */
    function fundForResponses() external payable {
        // Allow funding the contract
    }

    /**
     * @notice Emergency withdraw native tokens
     * @param _recipient Recipient address
     */
    function withdrawNative(address payable _recipient) external onlyOwner {
        if (_recipient == address(0)) revert InvalidAddress();
        uint256 balance = address(this).balance;
        (bool success,) = _recipient.call{value: balance}("");
        require(success, "Withdraw failed");
    }

    /**
     * @notice Emergency withdraw JPYC tokens
     * @param _recipient Recipient address
     * @param _amount Amount to withdraw
     */
    function emergencyWithdrawJPYC(address _recipient, uint256 _amount) external onlyOwner {
        if (_recipient == address(0)) revert InvalidAddress();
        jpycToken.safeTransfer(_recipient, _amount);
    }

    /**
     * @notice Allow contract to receive native tokens
     */
    receive() external payable {}
}
