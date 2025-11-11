// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {OApp, Origin, MessagingFee, MessagingReceipt} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface INLPMinterBurner {
    function burn(address from, uint256 amount) external;
}

/**
 * @title NLPOAppAdapter
 * @author NewLo Team
 * @notice LayerZero OApp adapter for locking NLP and managing cross-chain JPYC exchange
 * @dev Implements Lock/Unlock/Burn pattern with automatic failure recovery
 *
 * Key Features:
 * - Locks NLP tokens on source chain (doesn't burn immediately)
 * - Supports gasless transactions via ERC20Permit
 * - Sends cross-chain message to destination for JPYC exchange
 * - Receives success/failure callback from destination
 * - Burns NLP on success, unlocks on failure (automatic recovery)
 * - Provides exchange rate quotes for NLP to JPYC
 *
 * Message Flow:
 * 1. User calls sendWithPermit() -> Lock NLP
 * 2. Send GiftMessage to Chain B
 * 3. Chain B attempts JPYC transfer
 * 4. Chain B sends ResponseMessage back
 * 5. If success: Burn locked NLP
 *    If failure: Unlock NLP back to user
 */
contract NLPOAppAdapter is OApp, ReentrancyGuard {
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
     * @param amount Amount of NLP tokens locked
     */
    struct GiftMessage {
        address recipient;
        uint256 amount;
    }

    /**
     * @notice Response message from destination chain
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

    /// @notice Emitted when NLP is locked
    event NLPLocked(address indexed user, uint256 amount, uint32 indexed dstEid);

    /// @notice Emitted when NLP is burned after successful exchange
    event NLPBurned(address indexed user, uint256 amount);

    /// @notice Emitted when NLP is unlocked after failed exchange
    event NLPUnlocked(address indexed user, uint256 amount);

    /// @notice Emitted when exchange rate is updated
    event ExchangeRateUpdated(uint256 oldRate, uint256 newRate);

    /// @notice Emitted when gas limit is updated
    event GasLimitUpdated(uint256 oldLimit, uint256 newLimit);

    /* ═══════════════════════════════════════════════════════════════════════
                                   ERRORS
    ═══════════════════════════════════════════════════════════════════════ */

    error InvalidAmount();
    error InvalidAddress();
    error PermitFailed();
    error InsufficientFee();
    error NoLockedTokens();

    /* ═══════════════════════════════════════════════════════════════════════
                               IMMUTABLE STATE
    ═══════════════════════════════════════════════════════════════════════ */

    /// @notice NewLoPoint token on source chain
    IERC20Permit public immutable nlpToken;

    /// @notice Minter/Burner contract for NLP
    INLPMinterBurner public immutable minterBurner;

    /* ═══════════════════════════════════════════════════════════════════════
                              MUTABLE STATE
    ═══════════════════════════════════════════════════════════════════════ */

    /// @notice Locked NLP balances per user
    mapping(address => uint256) public lockedBalances;

    /// @notice Exchange rate from NLP to JPYC (denominator: 10000)
    /// @dev 10000 = 1:1, 9000 = 0.9:1, etc.
    uint256 public nlpToJpycRate = 10000;

    /// @notice Rate denominator for precision
    uint256 public constant RATE_DENOMINATOR = 10000;

    /// @notice Gas limit for destination lzReceive
    uint128 public gasLimit = 200_000;

    /* ═══════════════════════════════════════════════════════════════════════
                                 CONSTRUCTOR
    ═══════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Initialize the NLPOAppAdapter
     * @param _nlpToken Address of the NewLoPoint token contract on source chain
     * @param _minterBurner Contract with burn privileges
     * @param _endpoint Address of LayerZero Endpoint V2 on source chain
     * @param _owner Address that will have owner privileges
     */
    constructor(address _nlpToken, address _minterBurner, address _endpoint, address _owner)
        OApp(_endpoint, _owner)
        Ownable(_owner)
    {
        if (_nlpToken == address(0)) revert InvalidAddress();
        if (_minterBurner == address(0)) revert InvalidAddress();

        nlpToken = IERC20Permit(_nlpToken);
        minterBurner = INLPMinterBurner(_minterBurner);

        // Approve minter burner to burn from this contract
        IERC20(_nlpToken).forceApprove(_minterBurner, type(uint256).max);
    }

    /* ═══════════════════════════════════════════════════════════════════════
                            SEND FUNCTIONS
    ═══════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Send NLP cross-chain using permit for gasless approval
     * @param _dstEid Destination endpoint ID
     * @param _recipient Recipient address on destination chain
     * @param _amount Amount of NLP to send
     * @param _options Execution options (gas limit, etc.)
     * @param _deadline Permit deadline timestamp
     * @param _v Signature v component
     * @param _r Signature r component
     * @param _s Signature s component
     * @return receipt Messaging receipt from LayerZero
     */
    function sendWithPermit(
        uint32 _dstEid,
        address _recipient,
        uint256 _amount,
        bytes calldata _options,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external payable nonReentrant returns (MessagingReceipt memory receipt) {
        if (_amount == 0) revert InvalidAmount();
        if (_recipient == address(0)) revert InvalidAddress();
        if (block.timestamp > _deadline) revert PermitFailed();

        // Execute permit to approve this contract
        try nlpToken.permit(msg.sender, address(this), _amount, _deadline, _v, _r, _s) {
        // Permit successful
        }
        catch {
            revert PermitFailed();
        }

        // Transfer NLP from user to this contract (lock it)
        // Note: No need for transferFrom since permit already approved
        IERC20(address(nlpToken)).safeTransferFrom(msg.sender, address(this), _amount);

        // Update locked balance
        lockedBalances[msg.sender] += _amount;

        // Build and send message
        bytes memory message = abi.encode(MessageType.REQUEST, GiftMessage({recipient: _recipient, amount: _amount}));

        bytes memory options = _options.length > 0 ? _options : _buildOptions();

        // Quote fee
        MessagingFee memory fee = _quote(_dstEid, message, options, false);
        if (msg.value < fee.nativeFee) revert InsufficientFee();

        // Send message
        receipt = _lzSend(_dstEid, message, options, MessagingFee(msg.value, 0), payable(msg.sender));

        emit NLPLocked(msg.sender, _amount, _dstEid);

        return receipt;
    }

    /**
     * @notice Send NLP cross-chain (requires prior approval)
     * @param _dstEid Destination endpoint ID
     * @param _recipient Recipient address on destination chain
     * @param _amount Amount of NLP to send
     * @param _options Execution options (gas limit, etc.)
     * @return receipt Messaging receipt from LayerZero
     */
    function send(uint32 _dstEid, address _recipient, uint256 _amount, bytes calldata _options)
        external
        payable
        nonReentrant
        returns (MessagingReceipt memory receipt)
    {
        if (_amount == 0) revert InvalidAmount();
        if (_recipient == address(0)) revert InvalidAddress();

        // Transfer NLP from user to this contract (lock it)
        IERC20(address(nlpToken)).safeTransferFrom(msg.sender, address(this), _amount);

        // Update locked balance
        lockedBalances[msg.sender] += _amount;

        // Build and send message
        bytes memory message = abi.encode(MessageType.REQUEST, GiftMessage({recipient: _recipient, amount: _amount}));

        bytes memory options = _options.length > 0 ? _options : _buildOptions();

        // Quote fee
        MessagingFee memory fee = _quote(_dstEid, message, options, false);
        if (msg.value < fee.nativeFee) revert InsufficientFee();

        // Send message
        receipt = _lzSend(_dstEid, message, options, MessagingFee(msg.value, 0), payable(msg.sender));

        emit NLPLocked(msg.sender, _amount, _dstEid);

        return receipt;
    }

    /* ═══════════════════════════════════════════════════════════════════════
                            RECEIVE FUNCTIONS
    ═══════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Receive callback from destination chain
     * @dev _origin Origin information (source chain and sender)
     * @dev _guid Global unique identifier
     * @param _message Encoded ResponseMessage
     * @dev _executor Executor address
     * @dev _extraData Extra data from executor
     */
    function _lzReceive(
        Origin calldata,
        /*_origin*/
        bytes32,
        /*_guid*/
        bytes calldata _message,
        address,
        /*_executor*/
        bytes calldata /*_extraData*/
    )
        internal
        override
        nonReentrant
    {
        // Decode message type
        (MessageType msgType, bytes memory data) = abi.decode(_message, (MessageType, bytes));

        // Only process RESPONSE messages
        if (msgType != MessageType.RESPONSE) revert("Invalid message type");

        // Decode response
        ResponseMessage memory response = abi.decode(data, (ResponseMessage));

        if (response.amount == 0) revert InvalidAmount();
        if (response.user == address(0)) revert InvalidAddress();

        // Check user has locked tokens
        if (lockedBalances[response.user] < response.amount) revert NoLockedTokens();

        // Reduce locked balance
        lockedBalances[response.user] -= response.amount;

        if (response.success) {
            // JPYC transfer succeeded -> Burn NLP
            minterBurner.burn(address(this), response.amount);
            emit NLPBurned(response.user, response.amount);
        } else {
            // JPYC transfer failed -> Unlock NLP back to user
            IERC20(address(nlpToken)).safeTransfer(response.user, response.amount);
            emit NLPUnlocked(response.user, response.amount);
        }
    }

    /* ═══════════════════════════════════════════════════════════════════════
                            QUOTE FUNCTIONS
    ═══════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Quote the fee for sending tokens
     * @param _dstEid Destination endpoint ID
     * @param _recipient Recipient address
     * @param _amount Amount of tokens
     * @param _options Execution options
     * @param _payInLzToken Whether to pay in LZ token
     * @return fee Messaging fee
     */
    function quoteSend(uint32 _dstEid, address _recipient, uint256 _amount, bytes calldata _options, bool _payInLzToken)
        external
        view
        returns (MessagingFee memory fee)
    {
        bytes memory message = abi.encode(MessageType.REQUEST, GiftMessage({recipient: _recipient, amount: _amount}));

        bytes memory options = _options.length > 0 ? _options : _buildOptions();

        return _quote(_dstEid, message, options, _payInLzToken);
    }

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
     * @notice Update gas limit for destination execution
     * @param _newLimit New gas limit
     */
    function setGasLimit(uint128 _newLimit) external onlyOwner {
        uint256 oldLimit = gasLimit;
        gasLimit = _newLimit;
        emit GasLimitUpdated(oldLimit, _newLimit);
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

    /* ═══════════════════════════════════════════════════════════════════════
                            INTERNAL FUNCTIONS
    ═══════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Build default options for message execution
     * @return options Encoded options
     */
    function _buildOptions() internal view returns (bytes memory) {
        return OptionsBuilder.newOptions().addExecutorLzReceiveOption(gasLimit, 0);
    }

    /**
     * @notice Allow contract to receive native tokens
     */
    receive() external payable {}
}
