// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IRouterClient} from "@chainlink/contracts-ccip/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/applications/CCIPReceiver.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface INLPMinterBurner {
    function burn(address from, uint256 amount) external;
}

/**
 * @title NLPCCIPAdapter
 * @author NewLo Team
 * @notice Chainlink CCIP adapter for locking NLP and managing cross-chain JPYC exchange
 * @dev Implements Lock/Unlock/Burn pattern with automatic failure recovery
 *
 * Key Features:
 * - Locks NLP tokens on source chain (doesn't burn immediately)
 * - Supports gasless transactions via ERC20Permit
 * - Sends cross-chain message to destination for JPYC exchange via CCIP
 * - Receives success/failure callback from destination
 * - Burns NLP on success, unlocks on failure (automatic recovery)
 * - Provides exchange rate quotes for NLP to JPYC
 * - Supports LINK or native token for CCIP fees
 *
 * Message Flow:
 * 1. User calls sendWithPermit() -> Lock NLP
 * 2. Send GiftMessage to Chain B via CCIP
 * 3. Chain B attempts JPYC transfer
 * 4. Chain B sends ResponseMessage back via CCIP
 * 5. If success: Burn locked NLP
 *    If failure: Unlock NLP back to user
 */
contract NLPCCIPAdapter is CCIPReceiver, Ownable, ReentrancyGuard {
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
    event NLPLocked(address indexed user, uint256 amount, bytes32 indexed messageId);

    /// @notice Emitted when NLP is burned after successful exchange
    event NLPBurned(address indexed user, uint256 amount);

    /// @notice Emitted when NLP is unlocked after failed exchange
    event NLPUnlocked(address indexed user, uint256 amount);

    /// @notice Emitted when exchange rate is updated
    event ExchangeRateUpdated(uint256 oldRate, uint256 newRate);

    /// @notice Emitted when gas limit is updated
    event GasLimitUpdated(uint256 oldLimit, uint256 newLimit);

    /// @notice Emitted when destination is configured
    event DestinationConfigured(uint64 indexed chainSelector, address indexed receiver);

    /* ═══════════════════════════════════════════════════════════════════════
                                   ERRORS
    ═══════════════════════════════════════════════════════════════════════ */

    error InvalidAmount();
    error InvalidAddress();
    error PermitFailed();
    error NotEnoughBalance(uint256 currentBalance, uint256 calculatedFees);
    error DestinationNotConfigured();
    error NoLockedTokens();

    /* ═══════════════════════════════════════════════════════════════════════
                               IMMUTABLE STATE
    ═══════════════════════════════════════════════════════════════════════ */

    /// @notice NewLoPoint token on source chain
    IERC20Permit public immutable nlpToken;

    /// @notice Minter/Burner contract for NLP
    INLPMinterBurner public immutable minterBurner;

    /// @notice CCIP Router
    IRouterClient public immutable ccipRouter;

    /// @notice LINK token for CCIP fees
    IERC20 public immutable linkToken;

    /* ═══════════════════════════════════════════════════════════════════════
                              MUTABLE STATE
    ═══════════════════════════════════════════════════════════════════════ */

    /// @notice Locked NLP balances per user
    mapping(address => uint256) public lockedBalances;

    /// @notice Destination chain selector (e.g., Polygon)
    uint64 public destinationChainSelector;

    /// @notice Receiver address on destination chain
    address public destinationReceiver;

    /// @notice Exchange rate from NLP to JPYC (denominator: 10000)
    /// @dev 10000 = 1:1, 9000 = 0.9:1, etc.
    uint256 public nlpToJpycRate = 10000;

    /// @notice Rate denominator for precision
    uint256 public constant RATE_DENOMINATOR = 10000;

    /// @notice Gas limit for destination ccipReceive
    uint256 public gasLimit = 200_000;

    /* ═══════════════════════════════════════════════════════════════════════
                                 CONSTRUCTOR
    ═══════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Initialize the NLPCCIPAdapter
     * @param _nlpToken Address of the NewLoPoint token contract on source chain
     * @param _minterBurner Contract with burn privileges
     * @param _ccipRouter CCIP router address on source chain
     * @param _linkToken LINK token address on source chain
     * @param _owner Address that will have owner privileges
     */
    constructor(address _nlpToken, address _minterBurner, address _ccipRouter, address _linkToken, address _owner)
        CCIPReceiver(_ccipRouter)
        Ownable(_owner)
    {
        if (_nlpToken == address(0)) revert InvalidAddress();
        if (_minterBurner == address(0)) revert InvalidAddress();
        if (_ccipRouter == address(0)) revert InvalidAddress();
        if (_linkToken == address(0)) revert InvalidAddress();

        nlpToken = IERC20Permit(_nlpToken);
        minterBurner = INLPMinterBurner(_minterBurner);
        ccipRouter = IRouterClient(_ccipRouter);
        linkToken = IERC20(_linkToken);

        // Approve minter burner to burn from this contract
        IERC20(_nlpToken).forceApprove(_minterBurner, type(uint256).max);
    }

    /* ═══════════════════════════════════════════════════════════════════════
                            SEND FUNCTIONS
    ═══════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Send NLP cross-chain using permit for gasless approval
     * @param _recipient Recipient address on destination chain
     * @param _amount Amount of NLP to send
     * @param _payInLink Whether to pay CCIP fees in LINK (true) or native (false)
     * @param _deadline Permit deadline timestamp
     * @param _v Signature v component
     * @param _r Signature r component
     * @param _s Signature s component
     * @return messageId CCIP message ID
     */
    function sendWithPermit(
        address _recipient,
        uint256 _amount,
        bool _payInLink,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external payable nonReentrant returns (bytes32 messageId) {
        if (_amount == 0) revert InvalidAmount();
        if (_recipient == address(0)) revert InvalidAddress();
        if (destinationChainSelector == 0 || destinationReceiver == address(0)) {
            revert DestinationNotConfigured();
        }
        if (block.timestamp > _deadline) revert PermitFailed();

        // Execute permit to approve this contract
        try nlpToken.permit(msg.sender, address(this), _amount, _deadline, _v, _r, _s) {
        // Permit successful
        }
        catch {
            revert PermitFailed();
        }

        // Transfer NLP from user to this contract (lock it)
        IERC20(address(nlpToken)).safeTransferFrom(msg.sender, address(this), _amount);

        // Update locked balance
        lockedBalances[msg.sender] += _amount;

        // Build CCIP message
        Client.EVM2AnyMessage memory evm2AnyMessage = _buildCCIPMessage(
            MessageType.REQUEST, abi.encode(GiftMessage({recipient: _recipient, amount: _amount})), _payInLink
        );

        // Get the fee required to send the message
        uint256 fees = ccipRouter.getFee(destinationChainSelector, evm2AnyMessage);

        if (_payInLink) {
            if (fees > linkToken.balanceOf(address(this))) {
                revert NotEnoughBalance(linkToken.balanceOf(address(this)), fees);
            }

            // Approve the Router to transfer LINK tokens
            linkToken.forceApprove(address(ccipRouter), fees);

            // Send the message through the router
            messageId = ccipRouter.ccipSend(destinationChainSelector, evm2AnyMessage);
        } else {
            if (fees > msg.value) {
                revert NotEnoughBalance(msg.value, fees);
            }

            // Send the message through the router
            messageId = ccipRouter.ccipSend{value: fees}(destinationChainSelector, evm2AnyMessage);

            // Refund excess native tokens
            if (msg.value > fees) {
                (bool success,) = msg.sender.call{value: msg.value - fees}("");
                require(success, "Refund failed");
            }
        }

        emit NLPLocked(msg.sender, _amount, messageId);

        return messageId;
    }

    /**
     * @notice Send NLP cross-chain (requires prior approval)
     * @param _recipient Recipient address on destination chain
     * @param _amount Amount of NLP to send
     * @param _payInLink Whether to pay CCIP fees in LINK (true) or native (false)
     * @return messageId CCIP message ID
     */
    function send(address _recipient, uint256 _amount, bool _payInLink)
        external
        payable
        nonReentrant
        returns (bytes32 messageId)
    {
        if (_amount == 0) revert InvalidAmount();
        if (_recipient == address(0)) revert InvalidAddress();
        if (destinationChainSelector == 0 || destinationReceiver == address(0)) {
            revert DestinationNotConfigured();
        }

        // Transfer NLP from user to this contract (lock it)
        IERC20(address(nlpToken)).safeTransferFrom(msg.sender, address(this), _amount);

        // Update locked balance
        lockedBalances[msg.sender] += _amount;

        // Build CCIP message
        Client.EVM2AnyMessage memory evm2AnyMessage = _buildCCIPMessage(
            MessageType.REQUEST, abi.encode(GiftMessage({recipient: _recipient, amount: _amount})), _payInLink
        );

        // Get the fee required to send the message
        uint256 fees = ccipRouter.getFee(destinationChainSelector, evm2AnyMessage);

        if (_payInLink) {
            if (fees > linkToken.balanceOf(address(this))) {
                revert NotEnoughBalance(linkToken.balanceOf(address(this)), fees);
            }

            // Approve the Router to transfer LINK tokens
            linkToken.forceApprove(address(ccipRouter), fees);

            // Send the message through the router
            messageId = ccipRouter.ccipSend(destinationChainSelector, evm2AnyMessage);
        } else {
            if (fees > msg.value) {
                revert NotEnoughBalance(msg.value, fees);
            }

            // Send the message through the router
            messageId = ccipRouter.ccipSend{value: fees}(destinationChainSelector, evm2AnyMessage);

            // Refund excess native tokens
            if (msg.value > fees) {
                (bool success,) = msg.sender.call{value: msg.value - fees}("");
                require(success, "Refund failed");
            }
        }

        emit NLPLocked(msg.sender, _amount, messageId);

        return messageId;
    }

    /* ═══════════════════════════════════════════════════════════════════════
                            RECEIVE FUNCTIONS
    ═══════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Handle incoming CCIP response messages
     * @param any2EvmMessage CCIP message
     */
    function _ccipReceive(Client.Any2EVMMessage memory any2EvmMessage) internal override nonReentrant {
        // Decode message type
        (MessageType msgType, bytes memory data) = abi.decode(any2EvmMessage.data, (MessageType, bytes));

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
     * @notice Get CCIP fee for sending tokens
     * @param _recipient Recipient address
     * @param _amount Amount of tokens
     * @param _payInLink Whether to pay in LINK
     * @return fee CCIP fee amount
     */
    function getFee(address _recipient, uint256 _amount, bool _payInLink) external view returns (uint256 fee) {
        if (destinationChainSelector == 0) revert DestinationNotConfigured();

        Client.EVM2AnyMessage memory message = _buildCCIPMessage(
            MessageType.REQUEST, abi.encode(GiftMessage({recipient: _recipient, amount: _amount})), _payInLink
        );

        return ccipRouter.getFee(destinationChainSelector, message);
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
     * @notice Configure destination chain
     * @param _chainSelector Destination chain selector
     * @param _receiver Receiver contract address on destination
     */
    function configureDestination(uint64 _chainSelector, address _receiver) external onlyOwner {
        if (_chainSelector == 0) revert InvalidAddress();
        if (_receiver == address(0)) revert InvalidAddress();

        destinationChainSelector = _chainSelector;
        destinationReceiver = _receiver;

        emit DestinationConfigured(_chainSelector, _receiver);
    }

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
    function setGasLimit(uint256 _newLimit) external onlyOwner {
        uint256 oldLimit = gasLimit;
        gasLimit = _newLimit;
        emit GasLimitUpdated(oldLimit, _newLimit);
    }

    /**
     * @notice Withdraw LINK tokens
     * @param _recipient Recipient address
     * @param _amount Amount to withdraw
     */
    function withdrawLink(address _recipient, uint256 _amount) external onlyOwner {
        if (_recipient == address(0)) revert InvalidAddress();
        linkToken.safeTransfer(_recipient, _amount);
    }

    /**
     * @notice Withdraw native tokens
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
     * @notice Build CCIP message
     * @param _msgType Message type
     * @param _data Encoded message data
     * @param _payInLink Whether to pay in LINK
     * @return message CCIP EVM2Any message
     */
    function _buildCCIPMessage(MessageType _msgType, bytes memory _data, bool _payInLink)
        internal
        view
        returns (Client.EVM2AnyMessage memory)
    {
        // Encode message type and data
        bytes memory messageData = abi.encode(_msgType, _data);

        return Client.EVM2AnyMessage({
            receiver: abi.encode(destinationReceiver),
            data: messageData,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({gasLimit: gasLimit, allowOutOfOrderExecution: true})
            ),
            feeToken: _payInLink ? address(linkToken) : address(0)
        });
    }

    /**
     * @notice Allow contract to receive native tokens
     */
    receive() external payable {}
}
