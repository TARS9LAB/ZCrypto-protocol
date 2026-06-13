

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

contract RandomSeedUtil is VRFConsumerBaseV2Plus {

    // ======= VRF 参数 =======
    // 修复：subscriptionId应该是uint64类型
    uint256 public s_subscriptionId;
    // 使用正确的VRF协调器地址
    address public vrfCoordinator = 0xd691f04bc0C9a24Edb78af9E005Cf85768F694C9;
    // 使用正确的keyHash
    bytes32 public s_keyHash = 0x130dba50ad435d4ecc214aad0d5820474137bd68e7e77724144f27c3c377d3d4;
    uint32 public callbackGasLimit = 35000;
    uint16 public requestConfirmations = 3;
    uint32 public numWords = 1;
    uint256 public lastRequestId;
    uint256 public randomSeed;
    bool public randomReady;

    mapping(uint256 => address) private s_rollers;
    mapping(address => uint256) private s_results;

    address public dev;

    event RandomGenerated(uint256 indexed requestId, uint256 indexed seed);
    event RandomRequested(uint256 indexed requestId);

    // 自定义修饰符：owner 或 dev
    modifier onlyOwnerOrDev() {
        require(msg.sender == owner() || msg.sender == dev, "Not owner or dev");
        _;
    }

    // ======= 构造函数 =======
    constructor(
        uint256 subscriptionId,
        address _vrfCoordinator,
        address _dev
    )
    VRFConsumerBaseV2Plus(_vrfCoordinator)
    {
        s_subscriptionId = subscriptionId;
        dev = _dev;
    }

    // ======= VRF 随机数逻辑 =======
    function getRandom() external onlyOwnerOrDev returns (uint256 requestId) {
        // 正确的VRF请求
        requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: s_keyHash,
                subId: s_subscriptionId, // 现在是正确的uint64类型
                requestConfirmations: requestConfirmations,
                callbackGasLimit: callbackGasLimit,
                numWords: numWords,
                // 使用LINK支付
                extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: true}))
            })
        );
        return requestId;
    }

    /// @notice Chainlink 回调函数
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal override {
        require(randomWords.length > 0, "No random words received");
        randomSeed = randomWords[0];
        emit RandomGenerated(requestId, randomSeed);
    }

    // 方便 dev 转移权限
    function setDev(address newDev) external onlyOwner {
        dev = newDev;
    }

}
