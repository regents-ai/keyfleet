// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VRFV2PlusClient} from "../../src/vendor/chainlink/libraries/VRFV2PlusClient.sol";

/// @dev The parts of Chainlink's VRF v2.5 coordinator a fleet and the deployment scripts touch,
/// with the real coordinator's errors, bounds and request event: subscriptions with an owner and
/// consumers, the consumer check, the confirmation, gas and word bounds, the extra-args tag,
/// proving keys, and a callback made with exactly the requested gas whose revert is recorded and
/// not passed on. Request ids are computed as the real coordinator computes them, and a request
/// writes what the real one writes — one new slot and the consumer's nonce — so a purchase measured
/// against this mock costs about what it costs against the real coordinator.
/// `setRevertAll` makes every request revert, and `setRequestGasBurn` makes every request spend that
/// much more gas, so a test can starve it.
contract MockVRFCoordinatorV2Plus {
    error InvalidSubscription();
    error MustBeSubOwner(address owner);
    error InvalidConsumer(uint256 subId, address consumer);
    error InvalidRequestConfirmations(uint16 have, uint16 min, uint16 max);
    error GasLimitTooBig(uint32 have, uint32 want);
    error NumWordsTooBig(uint32 have, uint32 want);
    error InvalidExtraArgsTag();
    error NoCorrespondingRequest();
    error InsufficientGasForConsumer(uint256 have, uint256 want);
    error RequestsOff();

    /// @dev The real coordinator's request event, topic for topic.
    event RandomWordsRequested(
        bytes32 indexed keyHash,
        uint256 requestId,
        uint256 preSeed,
        uint256 indexed subId,
        uint16 minimumRequestConfirmations,
        uint32 callbackGasLimit,
        uint32 numWords,
        bytes extraArgs,
        address indexed sender
    );

    struct ProvingKey {
        bool exists;
        uint64 maxGas;
    }

    /// @dev The real coordinator's per-consumer slot.
    struct ConsumerConfig {
        bool active;
        uint64 nonce;
    }

    /// @dev What `fulfill` needs, in one slot.
    struct Pending {
        address sender;
        uint32 callbackGasLimit;
    }

    uint16 public constant MAX_REQUEST_CONFIRMATIONS = 200;
    uint32 public constant MAX_GAS_LIMIT = 2_500_000;
    uint32 public constant MAX_NUM_WORDS = 500;

    mapping(bytes32 keyHash => ProvingKey) public s_provingKeys;
    mapping(uint256 subId => address owner) public subscriptionOwner;
    mapping(uint256 subId => uint96 balance) public nativeBalance;
    mapping(uint256 subId => address[] consumers) private _consumers;
    mapping(address consumer => mapping(uint256 subId => ConsumerConfig)) public consumerConfig;
    mapping(uint256 requestId => Pending) public pending;
    /// @dev The two test switches share one slot, so reading them adds one cold read to a request,
    /// not two, and a measured purchase is inflated as little as possible.
    bool public revertAll;
    uint64 public requestGasBurn;
    uint256 private _subscriptions;

    /// @notice What the last `fulfill` saw: whether the callback succeeded and the gas it used.
    bool public lastCallbackSuccess;
    uint256 public lastCallbackGasUsed;

    function addProvingKey(bytes32 keyHash, uint64 maxGas) external {
        s_provingKeys[keyHash] = ProvingKey({exists: true, maxGas: maxGas});
    }

    function setRevertAll(bool on) external {
        revertAll = on;
    }

    function setRequestGasBurn(uint64 gasAmount) external {
        requestGasBurn = gasAmount;
    }

    function createSubscription() external returns (uint256 subId) {
        subId = uint256(keccak256(abi.encode(address(this), msg.sender, ++_subscriptions)));
        subscriptionOwner[subId] = msg.sender;
    }

    /// @notice Opens a subscription under a chosen id, so a second coordinator can know the same id.
    function openSubscription(uint256 subId, address owner) external {
        subscriptionOwner[subId] = owner;
    }

    function fundSubscriptionWithNative(uint256 subId) external payable {
        if (subscriptionOwner[subId] == address(0)) revert InvalidSubscription();
        nativeBalance[subId] += uint96(msg.value);
    }

    function addConsumer(uint256 subId, address consumer) external {
        address owner = subscriptionOwner[subId];
        if (owner == address(0)) revert InvalidSubscription();
        if (msg.sender != owner) revert MustBeSubOwner(owner);
        if (consumerConfig[consumer][subId].active) return;
        consumerConfig[consumer][subId].active = true;
        _consumers[subId].push(consumer);
    }

    function getSubscription(uint256 subId)
        external
        view
        returns (uint96 balance, uint96 native, uint64 reqCount, address owner, address[] memory consumers)
    {
        owner = subscriptionOwner[subId];
        if (owner == address(0)) revert InvalidSubscription();
        return (0, nativeBalance[subId], 0, owner, _consumers[subId]);
    }

    function requestRandomWords(VRFV2PlusClient.RandomWordsRequest calldata req) external returns (uint256 requestId) {
        if (revertAll) revert RequestsOff();
        if (requestGasBurn != 0) {
            uint256 available = gasleft();
            uint256 stop = available > requestGasBurn ? available - requestGasBurn : 0;
            while (gasleft() > stop) {}
        }
        if (subscriptionOwner[req.subId] == address(0)) revert InvalidSubscription();
        ConsumerConfig memory config = consumerConfig[msg.sender][req.subId];
        if (!config.active) revert InvalidConsumer(req.subId, msg.sender);
        if (req.requestConfirmations > MAX_REQUEST_CONFIRMATIONS) {
            revert InvalidRequestConfirmations(req.requestConfirmations, 0, MAX_REQUEST_CONFIRMATIONS);
        }
        if (req.callbackGasLimit > MAX_GAS_LIMIT) revert GasLimitTooBig(req.callbackGasLimit, MAX_GAS_LIMIT);
        if (req.numWords > MAX_NUM_WORDS) revert NumWordsTooBig(req.numWords, MAX_NUM_WORDS);
        if (bytes4(req.extraArgs) != VRFV2PlusClient.EXTRA_ARGS_V1_TAG) revert InvalidExtraArgsTag();

        ++config.nonce;
        uint256 preSeed;
        (requestId, preSeed) = computeRequestId(req.keyHash, msg.sender, req.subId, config.nonce);
        pending[requestId] = Pending({sender: msg.sender, callbackGasLimit: req.callbackGasLimit});
        consumerConfig[msg.sender][req.subId] = config;
        emit RandomWordsRequested(
            req.keyHash,
            requestId,
            preSeed,
            req.subId,
            req.requestConfirmations,
            req.callbackGasLimit,
            req.numWords,
            req.extraArgs,
            msg.sender
        );
    }

    /// @notice The id of a consumer's `nonce`th request on a subscription, as the real coordinator
    /// computes it.
    function computeRequestId(bytes32 keyHash, address sender, uint256 subId, uint64 nonce)
        public
        pure
        returns (uint256 requestId, uint256 preSeed)
    {
        preSeed = uint256(keccak256(abi.encode(keyHash, sender, subId, nonce)));
        requestId = uint256(keccak256(abi.encode(keyHash, preSeed)));
    }

    /// @notice Answers a pending request as the real coordinator does: the callback gets exactly the
    /// requested gas, its revert is recorded rather than passed on, and the request is gone either
    /// way.
    function fulfill(uint256 requestId, uint256[] calldata words) external returns (bool success) {
        Pending memory request = pending[requestId];
        if (request.sender == address(0)) revert NoCorrespondingRequest();
        delete pending[requestId];

        bytes memory data = abi.encodeWithSelector(0x1fe543e3, requestId, words);
        uint256 available = gasleft();
        if (available - available / 64 <= uint256(request.callbackGasLimit) + 10_000) {
            revert InsufficientGasForConsumer(available, request.callbackGasLimit);
        }
        uint256 before = gasleft();
        (success,) = request.sender.call{gas: request.callbackGasLimit}(data);
        lastCallbackGasUsed = before - gasleft();
        lastCallbackSuccess = success;
    }
}
