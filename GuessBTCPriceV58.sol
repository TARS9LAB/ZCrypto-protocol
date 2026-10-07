
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface AggregatorV3Interface {
    /// @notice 读取 Chainlink Feed 最新一轮价格数据。
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    /// @notice 按 roundId 读取 Chainlink Feed 指定轮价格数据。
    function getRoundData(uint80) external view returns (uint80, int256, uint256, uint256, uint80);
    /// @notice 返回 Chainlink Feed 的价格小数位数。
    function decimals() external view returns (uint8);
}

interface IVRFCoordinator {
    struct RandomWordsRequest {
        bytes32 keyHash;
        uint256 subId;
        uint16 requestConfirmations;
        uint32 callbackGasLimit;
        uint32 numWords;
        bytes extraArgs;
    }
    /// @notice 向 VRF Coordinator 请求随机数。
    function requestRandomWords(RandomWordsRequest calldata req) external returns (uint256);
}

/// @title GuessBTCPrice v5.7（BetRoot + 64层 Sparse Merkle Settlement）
/// @notice BTC 精准价格竞猜公证/记账合约；本合约不持有真实 USDT，PHP/PredictMarket 根据链上承诺与挑战结果完成实际余额入账。
///
/// ============================================================
/// V5.5 核心变化
/// ============================================================
/// 【普通奖结算扩容】
///   - 下注仍由 BetRoot 承诺全部注单；合约不逐注存储。
///   - >=10~  注非决胜局不再调用 submitSmallGroups 逐 DIFF 上链，改为一次提交 64 层 Sparse Merkle SettlementRoot。
///   - SMT key = uint64(diff)，diff 为 |guess-settlePrice| 的 0.0001 USD 单位整数；树中承诺本轮全部实际 DIFF Group。
///   - Settlement Group value = (groupIndex,count,prefixBefore,outcome,tier,amountEach)。
///   - 合约验证第一组、cutoff 组、最后一组锚点，并用真实 BetRoot proof 锚定 bestDiff 至少存在一笔真实下注。
///   - proveOmittedWinner 使用 BetRoot proof + SMT Non-Inclusion proof 证明“应中奖 DIFF 被完全遗漏”。
///   - proveBadSettlementGroup 使用 SMT Inclusion proof（及相邻组 proof）证明 prefix/outcome/tier/amount 等申报错误。
///
/// 【SMT V1 固定协议】
///   - 固定深度 64；key 路径唯一。proof[0] 对应 bit0，proof[63] 对应 bit63；0=Left，1=Right。
///   - Leaf/Branch/Empty 使用 0x00/0x01/0x02 域分离；非空 Leaf 绑定 domain、chainId、contract、roundId、diff、valueHash。
///   - Non-Inclusion 从 EMPTY[0] 沿该 key 唯一路径与 64 个 sibling 复算到 Root。
///
/// 【资金规则】
///   - 所有正常结算的有注轮统一计提本局投注额 10% 运营费；流局不收费，已临时计提的 10% 也全部回滚，并由 PHP 100% 退款。
///   - 非决胜且 <10~ 注：90% 滚存 / 10% 运营费，不设普通奖。
///   - 非决胜且 >=10~ 注：固定10%运营费 + 固定20%普通奖基金，剩余（含整数尾差）全部滚存，约70%。
///   - 决胜局：本局 10% 运营费、90% 并入历史 pool；圈内有人时总池 60% 冠军 + 40% 圈奖，圈空时 100% 冠军。
///
/// 【周期有效轮定义】
///   - cycleMaxRounds（例如 288）只统计“有下注且正常完成结算”的有效轮次。
///   - 空局（betCount==0）不计入周期轮数，不改变 pool/totalRake，不结束周期；若已到强制决胜位，资格顺延到下一有注轮。
///   - 流局同样不计入周期轮数，并回滚本轮临时账务，由 PHP 100% 退款。
///
/// 【最终性与挑战】
///   - CHALLENGE_WINDOW = 5 或者 10 minutes。
///   - settleFinish 后开奖结果立即可展示，但 PHP 仅在挑战窗口结束且 fraud=false 后正式入账；不再使用逐注链上 Claim。
///   - 挑战窗口可与下一轮并行；非决胜 state5 不阻塞下一 10 分钟格点。
///
/// 【仍保留的 V5.4 逻辑】
///   - 10 分钟格点 / 前 5 分钟下注 / 2 分钟开局宽限、Chainlink 结算、VRF 三路决胜、周期计数、流局机制。
///   - 决胜 ±10U 圈奖当前仍沿用 submitCircleGroups 分组锁定；本次 SMT 改造先解决普通奖海量 DIFF 上链瓶颈。
/// ============================================================
contract GuessBTCPriceV58 {
    // ==================== 自定义错误（压缩部署字节码） ====================
    /// @dev 使用 Custom Error 代替长 revert string，降低 EIP-170 runtime code size；
    ///      仅改变失败返回的 ABI 编码，不改变任何校验条件、状态机或资金规则。
    error AlreadyFulfilledErr(); // 原提示：Already fulfilled
    error AlreadyRankedErr(); // 原提示：Already ranked
    error AlreadyRequestedErr(); // 原提示：Already requested
    error BadAnswerErr(); // 原提示：Bad answer
    error BadBestBetProofErr(); // 原提示：Bad best bet proof
    error BadBetProofErr(); // 原提示：Bad bet proof
    error BadChampCountErr(); // 原提示：Bad champCount
    error BadCircleErr(); // 原提示：Bad circle
    error BadCircleCountErr(); // 原提示：Bad circleCount
    error BadCurrentProofErr(); // 原提示：Bad current proof
    error BadCutoffGroupErr(); // 原提示：Bad cutoff group
    error BadCutoffModeErr(); // 原提示：Bad cutoff mode
    error BadCutoffProofErr(); // 原提示：Bad cutoff proof
    error BadFirstGroupErr(); // 原提示：Bad first group
    error BadFirstProofErr(); // 原提示：Bad first proof
    error BadGroupCountErr(); // 原提示：Bad groupCount
    error BadLastGroupErr(); // 原提示：Bad last group
    error BadLastProofErr(); // 原提示：Bad last proof
    error BadLevelErr(); // 原提示：Bad level
    error BadPreviousProofErr(); // 原提示：Bad previous proof
    error BadProofErr(); // 原提示：Bad proof
    error BadWinnerGroupsErr(); // 原提示：Bad winner groups
    error BadWordsErr(); // 原提示：Bad words
    error BestBetDiffErr(); // 原提示：Best bet diff
    error BetCountClosureErr(); // 原提示：Bet count closure
    error BeyondCutoffErr(); // 原提示：Beyond cutoff
    error ChallengeClosedErr(); // 原提示：Challenge closed
    error ChampCountMismatchErr(); // 原提示：Champ count mismatch
    error ChampGroupFirstErr(); // 原提示：Champ group first
    error CircleNotRankedErr(); // 原提示：Circle not ranked
    error CollisionIndexErr(); // 原提示：Collision index
    error CollisionOutcomeErr(); // 原提示：Collision outcome
    error CollisionPrefixErr(); // 原提示：Collision prefix
    error CollisionPrizeErr(); // 原提示：Collision prize
    error CollisionWinnersErr(); // 原提示：Collision winners
    error ConfOutOfRangeErr(); // 原提示：Conf out of range
    error CountMismatchErr(); // 原提示：Count mismatch
    error CountSumErr(); // 原提示：Count sum
    error CutoffDiffErr(); // 原提示：Cutoff diff
    error DupGroupErr(); // 原提示：Dup group
    error DupProofErr(); // 原提示：Dup proof
    error EmptyRoundErr(); // 原提示：Empty round
    error ExactIndexErr(); // 原提示：Exact index
    error ExactPrefixErr(); // 原提示：Exact prefix
    error ExactWinnersErr(); // 原提示：Exact winners
    error FeedDecimalsNotEqual8Err(); // 原提示：Feed decimals != 8
    error FinalRoundNoVRFErr(); // 原提示：Final round no VRF
    error FinalizedErr(); // 原提示：Finalized
    error FirstCountErr(); // 原提示：First count
    error FirstDiffErr(); // 原提示：First diff
    error FirstIndexErr(); // 原提示：First index
    error FirstPrefixErr(); // 原提示：First prefix
    error FraudProvenErr(); // 原提示：Fraud proven
    error GroupExistsErr(); // 原提示：Group exists
    error LastCountErr(); // 原提示：Last count
    error LastIndexErr(); // 原提示：Last index
    error LastOverflowErr(); // 原提示：Last overflow
    error LastPrefixErr(); // 原提示：Last prefix
    error LengthMismatchErr(); // 原提示：Length mismatch
    error NoBetsErr(); // 原提示：No bets
    error NoChampErr(); // 原提示：No champ
    error NoCollisionErr(); // 原提示：No collision
    error NoDataAtRoundErr(); // 原提示：No data at round
    error NoFraudErr(); // 原提示：No fraud
    error NoGroupsErr(); // 原提示：No groups
    error NoSettlementRootErr(); // 原提示：No settlement root
    error NoSuchRoundErr(); // 原提示：No such round
    error NoWinnerGroupsErr(); // 原提示：No winner groups
    error NotChampErr(); // 原提示：Not champ
    error NotCircleErr(); // 原提示：Not circle
    error NotCoordinatorErr(); // 原提示：Not coordinator
    error NotCurrentErr(); // 原提示：Not current
    error NotEmptyErr(); // 原提示：Not empty
    error NotExactCapErr(); // 原提示：Not exact cap
    error NotOperatorErr(); // 原提示：Not operator
    error NotOwnerErr(); // 原提示：Not owner
    error NotSortedErr(); // 原提示：Not sorted
    error OutOfBoundsErr(); // 原提示：Out of bounds
    error PaidBelowBaseErr(); // 原提示：Paid below base
    error PaidExceedsFundErr(); // 原提示：Paid exceeds fund
    error PaidWithoutWinnersErr(); // 原提示：Paid without winners
    error PoolBelowVRFThresholdErr(); // 原提示：Pool below VRF threshold
    error PrevNotSettledErr(); // 原提示：Prev not settled
    error PrevRequiredErr(); // 原提示：Prev required
    error PriceAfterTargetErr(); // 原提示：Price after target
    error NextRoundNotAfterTargetErr();  // 下一轮 Chainlink 报价时间仍未超过目标时间，说明当前 round 不是目标时间前最后一个 Tick
    error ReentrantErr(); // 原提示：Reentrant
    error RollbackMismatchErr(); // 原提示：Rollback mismatch
    error RootTooLateErr(); // 原提示：Root too late
    error RoundInProgressErr(); // 原提示：Round in progress
    error SmallFundInvariantErr(); // 原提示：Small fund invariant
    error StalePriceErr(); // 原提示：Stale price
    error TooEarlyErr(); // 原提示：Too early
    error TooManyCircleGroupsErr(); // 原提示：Too many circle groups
    error UnknownRequestErr(); // 原提示：Unknown request
    error UseFinalizeEmptyRoundErr(); // 原提示：Use finalizeEmptyRound
    error VRFRequestFailedErr(); // 原提示：VRF request failed
    error VoidConditionsNotMetErr(); // 原提示：Void conditions not met
    error WaitVRFErr(); // 原提示：Wait VRF
    error WaitNextSlotErr(); // 原提示：Wait next slot
    error WindowOpenErr(); // 原提示：Window open
    error WinnerCapErr(); // 原提示：Winner cap
    error WrongStateErr(); // 原提示：Wrong state
    error ZeroErr(); // 原提示：Zero
    error ZeroAddrErr(); // 原提示：Zero addr
    error ZeroCountErr(); // 原提示：Zero count
    error ZeroRootErr(); // 原提示：Zero root
    error ZeroSettlementRootErr(); // 原提示：Zero settlement root

    // ==================== 常量 ====================
    uint64 public constant BET_WINDOW = 5 minutes;      // 黑窗（下注窗口）时长
    uint64 public constant ROUND_DURATION = 10 minutes; // 轮时长
    uint64 public constant CIRCLE_TOLERANCE = 100000;    // 决胜圈范围：diff <= 10.000U（ 0.0001 USD单位 ）
        
    // ==================== 当前周期普通奖参数 ====================
	/// @notice 当前周期普通奖基金比例，BPS。
	/// @dev 默认 45%；只在新周期开始时从 NEXT_SMALL_BPS 更新。
	uint256 public SMALL_BPS = 4500;
	/// @notice 当前周期开启普通奖所需最低注数。
	/// @dev 默认 10 注；只在新周期开始时从 NEXT_MIN_SMALL_BETS 更新。
	uint256 public MIN_SMALL_BETS = 10;
	/// @notice 当前周期普通奖最大中奖注数比例，BPS。
	/// @dev 默认 30%；只在新周期开始时从 NEXT_WIN_CAP_BPS 更新。
	uint256 public WIN_CAP_BPS = 3000;
	
	// ==================== 下一周期普通奖参数 ====================
	/// @notice 下一周期普通奖基金比例；默认 45%。
	uint256 public NEXT_SMALL_BPS = 4500;
	/// @notice 下一周期普通奖开启最低注数；默认 10 注。
	uint256 public NEXT_MIN_SMALL_BETS = 10;
	/// @notice 下一周期普通奖最大中奖注数比例；默认 30%。
	uint256 public NEXT_WIN_CAP_BPS = 3000;

        
    // 平台费固定 10%，实际由 RAKE_BPS=1000 计算；>=10 注时另计 20%-80% 普通奖基金，其余全部进入 pool。
    uint256 public constant CHAMP_BPS = 6000;           // 决胜且圈内有人时：总池的 60% 作为冠军预算
    uint256 public constant CIRCLE_BPS = 4000;          // 决胜七级奖预算 = 总池的 40%
    uint256 public constant LADDER_LINE = 100_000;      // 升档线系数：池子(USDT) >= 10万 × 票价(USDT)
    uint256 public constant MIN_CYCLE_ROUNDS = 1;        // 周期有效轮数下限；1 表示首个有注结算轮即为强制决胜位
    uint256 public constant MAX_CYCLE_ROUNDS = 100_000;  // 周期有效轮数上限
    uint64 public constant ROOT_GRACE = 1 hours;        // 关窗后锚根宽限
    uint64 public constant SETTLE_GRACE = 2 minutes;    // 每个10分钟格点开始后允许 startRound 的开局宽限
    uint64 public constant ORACLE_STALE = 6 hours;      // _priceAt 的价格新鲜度窗口，同时用于 _oracleDead 判定
    uint64 public constant FINAL_GRACE = 24 hours;      // state 1/2/3/4 的 24h 卡死逃生阈值（按各分支基准时间判断）
    uint64 public constant VRF_GRACE = 2 hours;         // state 2 超过 priceTime+该阈值即可触发流局条件

    uint64 public constant SMALL_CHALLENGE_WINDOW = 5 minutes; // 普通奖 挑战期 5分钟
    uint64 public constant CHALLENGE_WINDOW = 10 minutes; //  决胜轮 10分钟挑战期，settleFinish 后挑战窗口；窗口结束且 fraud=false 后 PHP 才正式入账
    
 
    uint256 public constant RAKE_BPS = 1000;            // 所有正常有注轮统一 10% 运营费
    uint8 public constant SMT_DEPTH = 64;
    uint8 public constant SMALL_OUTCOME_LOSER = 0;
    uint8 public constant SMALL_OUTCOME_WINNER = 1;
    uint8 public constant SMALL_TIER_NONE = 255;
    uint8 public constant CUTOFF_COLLISION = 1;          // cutoff 自身为第一组 losing group：diff < cutoff 才属于赢家区
    uint8 public constant CUTOFF_EXACT = 2;              // cutoff 自身为最后一组 winner：diff <= cutoff 属于赢家区
    bytes32 public constant SMT_DOMAIN = keccak256("ZCRYPTO_GUESS_SMALL_SETTLEMENT_SMT_V1");

    // 普通奖档界（累计名额）与 bonus 权重：七档权重=0——七档只吃 1.01× 票面地板，
    // bonus 池（基金 − 名额×地板价）按权重全归前六档（头档最重）
    uint16[6] public TIER_CUM = [1, 4, 14, 44, 144, 344];
    uint16[7] public TIER_W = [1500, 600, 250, 70, 12, 2, 0];

    // 决胜七级奖权重（±10U 圈，沿用 TIER_CUM 档界）：七档权重=1——圈内每注必得（>0），
    // 每注奖金 = 预算×档权重 / Σ(档权重×档注数) → 档越高每注越多，严格单调不倒挂
    uint16[7] public BTIER_W = [1500, 600, 250, 70, 12, 2, 1];

    // ==================== 轮状态 ====================
    // 0=Betting；1=Anchored；2=PriceSet；3=Declared(>=10~ 非决胜，等待 SettlementRoot)；4=Drawn；
    // 5=Rolled(非决胜终态)；6=Paying(决胜份额锁定)；7=Voiding；8=Voided；9=Done(决胜周期收尾)。
    // <500 非决胜：2→4→5；>=10~ 非决胜：2→3→submitSmallSettlement→4→5。
    // 决胜：2→4→submitCircleGroups(如有)→6→settleDone→9。
    struct Round {
        uint64 bettingClose;
        uint64 priceTime;
        uint64 anchoredAt;
        uint8 state;
        bytes32 root;            // BetRoot
        uint256 betCount;
        uint256 ticket;
        uint256 totalBetAmount;
        uint256 smallFund;       // 仅 >=10~ 非决胜：链上公式计算的 20%-80% 基金
        uint256 vrfRequestId;
        uint256 vrfWord;
        bool vrfReady;
        uint64 settlePrice;
        uint64 bestDiff;
        uint256 champCount;
        uint256 circleCount;

        // —— 普通奖 SMT 结算摘要 ——
        bytes32 settlementRoot;  // >=10~ 非决胜局的 64层 Sparse Merkle Root；其他轮为 0
        uint256 smallPaid;       // Operator 申报的普通奖实际总预算（<=smallFund）；公开数据可复算审计
        uint256 smallWinners;    // 实际中奖注数（<=15% cap）
        uint256 winnerGroupCount;// 中奖 DIFF group 数
        uint64 smallCutoff;      // COLLISION: 第一 losing diff；EXACT: 最后 winning diff
        uint8 smallCutoffMode;   // 1=COLLISION, 2=EXACT

        // —— 决胜 ——
        uint256 champShare;
        bool burst;
        uint64 burstLastDiff;
        uint256 circleGroups;
        uint256 burstRankCursor;
        uint256 burstTierSeq;

        uint256 groupCount;      // 全部实际 DIFF group 数（operator 申报，SMT 锚点与公开数据复核）
        bool fraud;
    }

    struct SmallGroupValue {
        uint256 groupIndex;      // 按 diff 严格升序，0 开始
        uint256 count;           // 当前 diff 注数
        uint256 prefixBefore;    // 所有更小 diff 的累计注数
        uint8 outcome;           // 0=LOSER, 1=SMALL_WIN
        uint8 tier;              // 0..6；LOSER 固定 255
        uint256 amountEach;      // 每注普通奖；LOSER 固定 0
    }

    struct SmallGroupWitness {
        uint64 diff;
        SmallGroupValue value;
        bytes32[64] siblings;    // siblings[0]=bit0 ... siblings[63]=bit63
    }

    struct BestBetWitness {
        address player;
        uint64 guess;
        uint256 nonce;
        bytes32[] proof;         // 原 BetRoot proof（V5 既有 sorted-pair Merkle）
    }

    struct SmallSettlementSubmission {
        bytes32 root;
        uint256 winnerGroupCount;
        uint256 smallWinners;
        uint256 smallPaid;
        uint64 smallCutoff;
        uint8 cutoffMode;
        SmallGroupWitness firstGroup;
        SmallGroupWitness cutoffGroup;
        SmallGroupWitness lastGroup;
        BestBetWitness bestBet;
    }

    // ==================== 存储 ====================
    address public owner;
    address public operator;                           // SIGNER：负责锚根、锚价、结算申报和奖组提交
    AggregatorV3Interface public feed;

    IVRFCoordinator public vrfCoordinator;
    bytes32 public vrfKeyHash;
    uint256 public vrfSubId;

    uint32 public vrfCallbackGasLimit = 200000;         // 回调仅写 vrfWord/vrfReady + 事件；200k 留足安全余量
    bool public vrfNativePayment = true;                // VRF 请求使用原生币计费；false 时使用 LINK 计费
    uint16 public vrfRequestConfirmations = 3;          // VRF requestConfirmations，setVrfConfig 限制在 [3,200]

    uint256 public nextCycleRounds = 6;                 // 下一周期有效轮数；owner 可调，新周期首轮快照
    uint256 public cycleMaxRounds;                      // 本周期生效值（新周期第 1 局开局时快照 nextCycleRounds；兼作 VRF 决胜模数）
    uint256 public cycleRoundCount;                     // 本周期已有效结算轮数（流局/空局不计；决胜位 = cycleRoundCount+1 >= cycleMaxRounds）
    uint256 public nextMinVrfJackpot = 0;               // VRF 爆池门槛（下一阶段值，owner 可调；首期默认 0U ）
    uint256 public currentMinVrfJackpot;                // 本周期快照：周期中途改 next 绝不影响本期
    bool public needNewCycle = true;                    // 下一轮开启新周期
    mapping(uint256 => uint256) private _countedCycle;  // 当前实现未读写；保留的兼容存储槽位

	// 延续旧合约，从46局开始
    uint256 public cycleId = 45;                   
	// 延续旧合约编号，首次开局使用5919
	uint256 private constant ROUND_ID_BASE = 5918;
	// 部署后保持0，表示尚未开局，兼容Keeper原有判断。
	uint256 public currentRoundId;
	
	// 滚存奖池（USDT wei，账簿）
    uint256 public pool;
    /// @notice 已预约的赞助金额冲池子，仅在下一周期第一轮开局时加入 pool。
	uint256 public nextCyclePoolBonus;                    

    // 累计平台费（账簿）
    uint256 public totalRake;               

    mapping(uint256 => Round) public rounds;
    mapping(uint256 => uint256) public roundOfRequest;

    // 决胜圈仍沿用分组上链；不再保存逐注 claim 计数。
    mapping(uint256 => uint256[7]) private _burstTierBets;
    mapping(uint256 => uint256[7]) private _burstTierShare;
    mapping(uint256 => mapping(uint64 => uint8)) private _circleTierOf;
    mapping(uint256 => mapping(uint64 => uint256)) private _circleCountOf;

    mapping(uint256 => uint64) public finishAt;
    mapping(uint256 => uint256) private _champProven;
    mapping(uint256 => mapping(bytes32 => bool)) private _champProofUsed;

    bool private _locked;

    // ==================== 事件 ====================
    event RoundStarted(uint256 indexed roundId, uint256 indexed cycleId, uint64 bettingClose, uint64 priceTime, uint256 maxRounds);
    event BetRootAnchored(uint256 indexed roundId, bytes32 root, uint256 betCount, uint256 ticket);
    event VrfRequested(uint256 indexed roundId, uint256 requestId);
    event VrfFulfilled(uint256 indexed roundId, uint256 word);
    event PriceAnchored(uint256 indexed roundId, uint64 settlePrice);
    event ScanFinished(uint256 indexed roundId, uint64 bestDiff, uint256 champCount, uint256 circleCount, bool burst, uint256 totalBetAmount, uint256 smallFund); // 结算摘要事件；名称保留，但当前实现不存在链上逐注扫描
    event SmallSettlementCommitted(
        uint256 indexed roundId, bytes32 indexed settlementRoot, uint256 groupCount, uint256 winnerGroupCount,
        uint256 winners, uint256 paid, uint64 cutoff, uint8 cutoffMode
    );
    event SmallPrizesDone(uint256 indexed roundId, uint256 winners, uint256 paid);
    // —— 决胜七级奖专用事件（与普通奖 SmallWin 互不混用）——
    event BurstTierGroup(uint256 indexed roundId, uint256 indexed groupId, uint64 diff, uint8 tier, uint256 count); // 圈组分档：按 diff 升序逐组 emit
    event BurstPrizesRanked(uint256 indexed roundId, uint256 budget, uint256[7] tierShares); // 决胜七级奖锁定：budget=当前总池40%，记录各档每注份额
    event RoundRolled(uint256 indexed roundId, uint256 indexed cycleId, uint256 poolAfter);
    event BurstSettled(uint256 indexed roundId, uint256 indexed cycleId, uint256 pool, uint256 champPart, uint256 circlePart, uint256 fee);
    event RakeAccrued(uint256 indexed roundId, uint256 rakeDelta, uint256 totalRake); // 仅正常有注轮计提平台费；空局不收费，流局回滚本轮已临时计提的平台费
    event VoidStarted(uint256 indexed roundId, string reason);
    event VoidFinalized(uint256 indexed roundId);
    event CycleRoundsUpdated(uint256 oldRounds, uint256 newRounds);   // 更新 nextCycleRounds；下一周期生效
    event MinVrfJackpotUpdated(uint256 oldNext, uint256 newNext); // 改的是下一阶段值；本周期按快照执行
    event VrfConfigUpdated(address indexed coordinator, bytes32 keyHash, uint256 subId, bool nativePayment, uint16 confirmations);
    event OperatorUpdated(address indexed oldOp, address indexed newOp);
    // ==================== 结算 / 挑战事件 ====================
    event SettlementDeclared(uint256 indexed roundId, uint64 bestDiff, uint256 champCount, uint256 circleCount, uint256 groupCount);
    event OperatorFraud(uint256 indexed roundId, bytes32 indexed leaf, uint64 declaredBestDiff, uint64 provenDiff); // proveFraud 时为申报/实证diff；冠军人数少报路径复用为申报数/已举证数
    event ChampProven(uint256 indexed roundId, bytes32 indexed leaf, uint256 proven);   // 冠军 leaf 举证累计；proven>champCount 时标记 fraud
    event SettlementFraud(uint256 indexed roundId, uint8 indexed reason, uint64 diff); // 1=omitted winner, 2=bad settlement group
    // settleFinish 前 state 3/4 的拆账仍可由 void 回滚；settleFinish 后只允许标错/补偿，不再经济回滚。
    event PreFinalRollback(uint256 indexed roundId, uint256 poolDelta, uint256 rakeDelta);
    event CompensationRequired(uint256 indexed roundId); // settleFinish 后挑战坐实错误：提示链下停止正常入账并执行补偿
    
    /// @notice 预约下一周期加池：本次金额、累计待加金额。
	event PoolBonusScheduled(uint256 indexed targetCycleId,uint256 amount,uint256 pendingTotal);
	/// @notice 下一周期第一轮开局，赞助正式计入奖池。
	event PoolBonusApplied(uint256 indexed cycleId,uint256 indexed roundId,uint256 amount,uint256 poolAfter);

    modifier onlyOwner() { if (!(msg.sender == owner)) revert NotOwnerErr(); _; }
    modifier onlyOperator() { if (!(msg.sender == operator)) revert NotOperatorErr(); _; }
    modifier nonReentrant() { if (!(!_locked)) revert ReentrantErr(); _locked = true; _; _locked = false; }

    /// @notice 初始化 BTC/USD Feed、VRF 配置与结算 operator。
    constructor(
        address _feed,
        address _vrfCoordinator,
        bytes32 _vrfKeyHash,
        uint256 _vrfSubId,
        address _operator
    ) {
        if (!(_feed != address(0) && _vrfCoordinator != address(0) && _operator != address(0))) revert ZeroAddrErr();
        owner = msg.sender;
        feed = AggregatorV3Interface(_feed);
        if (!(feed.decimals() == 8)) revert FeedDecimalsNotEqual8Err();   // _toPriceUnit 按 8 位小数换算：部署即锁定假设，接错 feed 当场拒绝
        vrfCoordinator = IVRFCoordinator(_vrfCoordinator);
        vrfKeyHash = _vrfKeyHash;
        vrfSubId = _vrfSubId;
        operator = _operator;
    }

    // ==================== 管理 ====================
    /// @notice 转移合约 owner；新地址不能为零地址。
    function transferOwnership(address n) external onlyOwner { if (!(n != address(0))) revert ZeroErr(); owner = n; }
    /// @notice 更新结算 operator 地址；仅 owner 可调用。
    function setOperator(address n) external onlyOwner { if (!(n != address(0))) revert ZeroErr(); emit OperatorUpdated(operator, n); operator = n; }
    /// @notice 更新 Chainlink VRF 回调 Gas Limit。
    function setVrfCallbackGasLimit(uint32 v) external onlyOwner { vrfCallbackGasLimit = v; }

    /// @notice owner 更新 VRF coordinator/keyHash/subId/计费方式/确认数。
    /// @dev 若已经开过轮，只允许当前轮处于 state 5/8/9 时修改；进行中轮次会 revert RoundInProgressErr()。
    ///      _coordinator 不能为零地址，_confirmations 必须在 [3,200]。
    ///      rawFulfillRandomWords 只接受“当前配置”的 vrfCoordinator，因此切换后来自旧 coordinator 的回调会被拒绝；
    ///      配置切换应在当前轮终态与下一轮 startRound 之间完成。
    function setVrfConfig(
        address _coordinator,
        bytes32 _keyHash,
        uint256 _subId,
        bool _nativePayment,
        uint16 _confirmations
    ) external onlyOwner {
        if (!(_coordinator != address(0))) revert ZeroAddrErr();
        if (!(_confirmations >= 3 && _confirmations <= 200)) revert ConfOutOfRangeErr();
        uint256 rid = currentRoundId;
        if (rid != 0) {
            uint8 st = rounds[rid].state;
            if (!(st == 5 || st == 8 || st == 9)) revert RoundInProgressErr();
        }
        vrfCoordinator = IVRFCoordinator(_coordinator);
        vrfKeyHash = _keyHash;
        vrfSubId = _subId;
        vrfNativePayment = _nativePayment;
        vrfRequestConfirmations = _confirmations;
        emit VrfConfigUpdated(_coordinator, _keyHash, _subId, _nativePayment, _confirmations);
    }

    /// @notice 调整周期长度（有效轮数）[1,100000]；仅 nextCycleRounds 改变，下一周期生效
    /// @dev 新周期首轮把 nextCycleRounds 快照到 cycleMaxRounds。
    ///      只有有下注且正常结算的有效轮才计入周期；空局/流局不增加，强制决胜资格顺延；决胜局由 settleDone 结束周期。
    function setCycleRounds(uint256 v) external onlyOwner {
        if (!(v >= MIN_CYCLE_ROUNDS && v <= MAX_CYCLE_ROUNDS)) revert OutOfBoundsErr();
        emit CycleRoundsUpdated(nextCycleRounds, v);
        nextCycleRounds = v;
    }

    /// @notice 更新 nextMinVrfJackpot；当前周期的 currentMinVrfJackpot 不立即改变。
    /// @dev 新周期首轮 startRound 才把 nextMinVrfJackpot 快照到 currentMinVrfJackpot。
    ///      v=0 时所有非空、非强制决胜位轮都满足 pool 门槛；较大值会减少 VRF 请求/随机决胜触发范围。
    function setMinVrfJackpot(uint256 v) external onlyOwner {
        emit MinVrfJackpotUpdated(nextMinVrfJackpot, v);
        nextMinVrfJackpot = v;
    }

	/// @notice owner 预约下一周期加池，金额采用 1e18 记账单位。
	/// @dev 多次调用累计；不修改当前周期 pool，不执行真实 USDT 转账。
	function schedulePoolBonus(uint256 amount) external onlyOwner {
		if (amount == 0) revert ZeroErr();
		nextCyclePoolBonus += amount;
		emit PoolBonusScheduled(cycleId + 1, amount, nextCyclePoolBonus);
	}

	/// @notice 设置下一周期普通奖参数。
	/// @dev
	/// - 最低开启注数 >= 10，无最大值；
	/// - 普通奖基金比例 20%～80%；
	/// - 中奖注数比例 3%～60%；
	/// - 普通奖基金比例必须至少是中奖比例的 1.3 倍；
	/// - 修改后不影响当前周期，只在下一周期开始时生效。
	function setSmallPrizeConfig(
		uint256 minSmallBets,
		uint256 smallBps,
		uint256 winCapBps
	) external onlyOwner {
		// 普通奖最低开启门槛不能低于 10 注。
		if (minSmallBets < 10) revert OutOfBoundsErr();
		// 普通奖基金比例只能设置为 20%～80%。
		if (smallBps < 2000 || smallBps > 8000) {
			revert OutOfBoundsErr();
		}
		// 普通奖中奖比例只能设置为 3%～60%。
		if (winCapBps < 300 || winCapBps > 6000) {
			revert OutOfBoundsErr();
		}
		// 普通奖基金比例至少是中奖注比例的 1.3 倍。
		// 例如：45% / 30% = 合法，因为 45 >= 30 × 1.3 = 39。
		if (smallBps * 10 < winCapBps * 13) {
			revert SmallFundInvariantErr();
		}
		// 只修改下一周期参数，当前周期完全不受影响。
		NEXT_MIN_SMALL_BETS = minSmallBets;
		NEXT_SMALL_BPS = smallBps;
		NEXT_WIN_CAP_BPS = winCapBps;
	}

    // ==================== 票价阶梯（纯函数，可链上验证） ====================
    /// @notice 1U 起步；池子 >= 10万U × 当前票价 → 升档（1→2→5→10→20→50…）
    function ticketForPool(uint256 _pool) public pure returns (uint256) {
        uint256 mantissa = 1;
        uint256 exp = 0;
        // 升档线：pool(wei) >= 10万 × mantissa×10^exp × 1e18
        while (_pool >= LADDER_LINE * mantissa * (10 ** exp) * 1e18) {
            if (mantissa == 1) mantissa = 2;
            else if (mantissa == 2) mantissa = 5;
            else { mantissa = 1; exp += 1; }
        }
        return mantissa * (10 ** exp) * 1e18;
    }

    // ==================== 小奖名额（当前周期参数，可链上查询） ====================
    /// @notice 普通奖中奖人数硬顶 = 注数 ×  当前周期 WIN_CAP_BPS（撞线即停：中奖组恒为最准前缀）
    /// @dev cap=floor(betCount*15%)；base=ticket*101/100。
    ///      V5.5 Settlement SMT 仍使用 smallFund-base*cap 作为 bonusPool；未实际派出的 smallFund 余额滚回 pool。
    function smallSlots(uint256 betCount) public view  returns (uint256) {
        return betCount * WIN_CAP_BPS / 10000;
    }

    // ==================== 开局（严格串行 + 真实世界10分钟格点） ====================
    /// @notice 开新一轮。规则：
    ///   1) 串行：上一轮必须已完整终结：滚存(5) / 流局(8) / 爆池完成(9)；
    ///   2) 网格：永远对齐 Unix 时间的 10 分钟整格（时间格即唯一真相，首局与后续局
    ///      同一条规则，不维护第二套时间锚）；仅允许格点后 SETTLE_GRACE(2分钟) 内
    ///      开局——错过本格就等下一格，绝不"迟开 10:00 局让玩家只剩 2 分钟下注"。
    ///   新局时刻钉在格点上：bettingClose=格点+5min, priceTime=格点+10min；
    ///   实际下注窗口 = 开局时刻 → 关窗（5 分钟封顶，被结算占用多少扣多少，最少 3 分钟）。
    function startRound() external nonReentrant {
        uint256 rid = currentRoundId;
        if (rid != 0) {                          // 1. 上一局必须已终结
            Round storage pr = rounds[rid];
            if (!(pr.state == 5 || pr.state == 8 || pr.state == 9)) revert PrevNotSettledErr();
        }
		// 首次使用旧合约编号基数，后面统一加1。
		rid = (rid == 0 ? ROUND_ID_BASE : rid);
		
        uint256 slotStart = block.timestamp / ROUND_DURATION * ROUND_DURATION;  // 2. 对齐真实世界格点
        if (!(block.timestamp <= slotStart + SETTLE_GRACE)) revert WaitNextSlotErr(); // 3. 仅格点后前 2 分钟
        if (needNewCycle) {
            cycleId += 1;
            cycleRoundCount = 0;                        // 新周期有效结算轮计数归零
            cycleMaxRounds = nextCycleRounds;           // 周期长度快照：本期定格，防"周期中途改长度"
            currentMinVrfJackpot = nextMinVrfJackpot;   // 门槛快照：本期定格，防"眼看要爆临时调高"            
            // ==================== 普通奖参数切换 ====================
			// owner 在上一周期调用 setSmallPrizeConfig() 修改的只是 NEXT 参数。
			// 只有新的 cycle 第 1 轮开始时，才正式更新当前周期参数。
			// 因此整个周期内所有轮次使用完全一致的普通奖规则。
			MIN_SMALL_BETS = NEXT_MIN_SMALL_BETS;
			SMALL_BPS = NEXT_SMALL_BPS;
			WIN_CAP_BPS = NEXT_WIN_CAP_BPS;
			// 预约赞助只在新周期第一轮开局时进入奖池。
			uint256 bonus = nextCyclePoolBonus;
			if (bonus > 0) {
				nextCyclePoolBonus = 0;
				pool += bonus;
				// 此处 rid 尚未执行后面的 +1，因此新轮编号为 rid + 1。
				emit PoolBonusApplied(cycleId, rid + 1, bonus, pool);
			}
            needNewCycle = false;
        }
        rid += 1;
        currentRoundId = rid;
        Round storage r = rounds[rid];
        r.bettingClose = uint64(slotStart) + BET_WINDOW;
        r.priceTime = uint64(slotStart) + ROUND_DURATION;
        r.state = 0;
        emit RoundStarted(rid, cycleId, r.bettingClose, r.priceTime, cycleMaxRounds);
    }

    // ==================== 黑窗关窗：锚定 Merkle 根 + 请求 VRF ====================
    /// @notice 仅 operator；关窗后一次性锚定。先锁注、后出随机数——连平台都无法预知。
    /// @dev 空局（betCount==0）允许零根，因为空局不存在需要 proof 的下注；
    ///      非空局必须提交非零 root，否则下注无法通过 Merkle proof 自证。
    function submitBetRoot(uint256 rid, bytes32 root, uint256 betCount) external onlyOperator nonReentrant {
        Round storage r = rounds[rid];
        if (!(rid == currentRoundId)) revert NotCurrentErr();
        if (!(r.state == 0)) revert WrongStateErr();
        if (!(block.timestamp >= r.bettingClose)) revert WindowOpenErr();
        if (!(block.timestamp <= r.bettingClose + ROOT_GRACE)) revert RootTooLateErr();
        if (!(betCount == 0 || root != bytes32(0))) revert ZeroRootErr();

        r.root = root;
        r.betCount = betCount;
        r.ticket = ticketForPool(pool);   // 每窗一价：锚根时定价，本轮同价
        r.anchoredAt = uint64(block.timestamp);
        r.state = 1;

        emit BetRootAnchored(rid, root, betCount, r.ticket);
    }

    /// @notice 为已锚根的轮请求 VRF 随机数（permissionless，费用由订阅承担）
    /// @dev 与 submitBetRoot 分离，确保 root/betCount 先锁定再请求随机数。
    ///      仅 state 1/2 可请求；同轮只允许一个 requestId。
    ///      三个拒绝条件：空局、pool 低于 currentMinVrfJackpot、当前轮已是强制决胜位。
    ///      严格串行下，在 settleDeclare 拆账前 pool 不会被本轮改变，因此请求门槛与判决门槛口径一致。
    function requestVrf(uint256 rid) external {
        Round storage r = rounds[rid];
        if (!(r.state == 1 || r.state == 2)) revert WrongStateErr();   // VRF 可在锚根后、锚价前后请求；未就绪时 settleDeclare 会 revert
        if (!(r.vrfRequestId == 0)) revert AlreadyRequestedErr();
        if (!(r.betCount > 0)) revert NoBetsErr();                                  // 空局：词无消费者
        if (!(pool >= currentMinVrfJackpot)) revert PoolBelowVRFThresholdErr();   // 池不够格：VRF 路径关闭
        if (!(cycleRoundCount + 1 < cycleMaxRounds)) revert FinalRoundNoVRFErr(); // 强制决胜位不使用随机数
        // VRF v2.5：extraArgs = abi.encodeWithSelector(0x92fd1338, nativePayment)
        bytes memory extraArgs = abi.encodeWithSelector(bytes4(0x92fd1338), vrfNativePayment);
        try vrfCoordinator.requestRandomWords(IVRFCoordinator.RandomWordsRequest({
            keyHash: vrfKeyHash,
            subId: vrfSubId,
            requestConfirmations: vrfRequestConfirmations,
            callbackGasLimit: vrfCallbackGasLimit,
            numWords: 1,
            extraArgs: extraArgs
        })) returns (uint256 reqId) {
            r.vrfRequestId = reqId;
            roundOfRequest[reqId] = rid;
            emit VrfRequested(rid, reqId);
        } catch {
            revert VRFRequestFailedErr();
        }
    }

    /// @notice VRF 回调（仅 coordinator）
    /// @dev 按 requestId 反查轮次（与 currentRoundId 解耦）；回调只落 vrfWord/vrfReady。
    ///      判决统一由 settleDeclare 完成，避免回调内做业务状态推进。
    function rawFulfillRandomWords(uint256 requestId, uint256[] memory randomWords) external {
        if (!(msg.sender == address(vrfCoordinator))) revert NotCoordinatorErr();
        if (!(randomWords.length == 1)) revert BadWordsErr();
        uint256 rid = roundOfRequest[requestId];
        if (!(rid != 0)) revert UnknownRequestErr();
        Round storage r = rounds[rid];
        if (!(!r.vrfReady)) revert AlreadyFulfilledErr();
        r.vrfWord = randomWords[0];
        r.vrfReady = true;
        emit VrfFulfilled(rid, randomWords[0]);
        // 回调只落随机词；是否决胜由 settleDeclare 根据当前规则统一判定
    }

    
    // ==================== 结算阶段一：锚定结算价 ====================
	/// @notice 非空局锚定结算价：operator 在 priceTime 后提交 Chainlink roundId。
	/// @dev 结算价采用“不晚于 priceTime 的最后一个 Chainlink Tick”。
	///      合约验证：
	///      1. candidate.updatedAt > 0
	///      2. candidate.answer > 0
	///      3. candidate.updatedAt <= priceTime
	///      4. candidate 距离 priceTime 不超过 ORACLE_STALE
	///      5. candidate 的下一 round.updatedAt > priceTime
	///      因此 operator 无法故意提交更早的历史报价。
	///      settleInit 可以在 priceTime 后调用，但如果下一 Chainlink Tick
	///      尚未产生，则验证无法完成，keeper 等待下一 Tick 后重试。
	///      betCount==0 被拒绝，空局只能调用 finalizeEmptyRound。
    function settleInit(uint256 rid, uint80 oracleRoundId) external nonReentrant onlyOperator {
        Round storage r = rounds[rid];
        if (!(r.state == 1)) revert WrongStateErr();
        if (!(r.betCount > 0)) revert UseFinalizeEmptyRoundErr();   // 空局唯一路径：finalizeEmptyRound
        if (!(block.timestamp >= r.priceTime)) revert TooEarlyErr();
        r.settlePrice = _priceAt(oracleRoundId, r.priceTime);
        r.state = 2;
        emit PriceAnchored(rid, r.settlePrice);
    }

    // ==================== 结算阶段二：operator 申报链下计算结果，合约验证并拆账 ====================
    /// @notice 申报 bestDiff、champCount、circleCount、circleGroupCount、groupCount。
    /// @dev 合约校验计数范围、圈内关系和决胜规则；totalBetAmount 固定为 betCount*ticket。
    ///      burst 判定：bestDiff==0 或强制决胜位直接为 true；否则仅当 pool 达到 VRF 门槛时
    ///      要求 vrfReady，并用 vrfWord % cycleMaxRounds < 2 判定随机决胜。
    ///      申报值可由公开下注和 Merkle root 复算；若存在 diff<bestDiff 的合法注，应通过 proveFraud 举证。
    function settleDeclare(
        uint256 rid,
        uint64 bestDiff,
        uint256 champCount,
        uint256 circleCount,
        uint256 circleGroupCount,
        uint256 groupCount
    ) external nonReentrant onlyOperator {
        Round storage r = rounds[rid];
        if (!(r.state == 2)) revert WrongStateErr();
        // —— 申报自洽性校验（链上可验的全部验掉）——
        if (!(champCount > 0 && champCount <= r.betCount)) revert BadChampCountErr();
        if (!(groupCount >= 1 && groupCount <= r.betCount)) revert BadGroupCountErr();
		// 圈内注数不可能超过本轮总注数
		if (!(circleCount <= r.betCount)) revert BadCircleCountErr();
        if (bestDiff <= CIRCLE_TOLERANCE) {
            if (!(circleCount >= champCount && circleGroupCount >= 1)) revert BadCircleErr(); // 冠军天然在圈内
        } else {
            if (!(circleCount == 0 && circleGroupCount == 0)) revert BadCircleErr();          // 圈外无圈组
        }
        if (!(circleCount >= circleGroupCount && groupCount >= circleGroupCount)) revert CountMismatchErr();

        // —— 决胜判决：自然命中 / 强制决胜位 / 达门槛后的 VRF 随机决胜 ——
        // 强制决胜位：本轮若作为下一有效轮将达到 cycleMaxRounds。
        // cycleRoundCount 只统计有下注且正常结算的有效轮；空局/流局均不增加，因此强制决胜资格会顺延。
        bool finalRound = cycleRoundCount + 1 >= cycleMaxRounds;
        bool burst = bestDiff == 0 || finalRound;                 // 路一/兜底：零 VRF 依赖
        if (!burst && pool >= currentMinVrfJackpot) {
            if (!(r.vrfReady)) revert WaitVRFErr();                      // 路二：词未回，等（keeper 轮询）
            burst = r.vrfWord % cycleMaxRounds < 2;               // 模数 = 周期轮数：每轮 2/N 爆点概率
        }

        r.bestDiff = bestDiff;
        r.champCount = champCount;
        r.circleCount = circleCount;
        r.circleGroups = circleGroupCount;
        r.groupCount = groupCount;
        r.burst = burst;

        // —— 按 betCount * ticket 锁定本局总额，并根据 burst/注数门槛拆账 ——
        uint256 t = r.betCount * r.ticket;
        r.totalBetAmount = t;
        uint256 small = 0;
        if (burst) {
            // 决胜局：本局统一 10% 运营费，剩余 90% 与历史 pool 合并。
            uint256 rake = t * RAKE_BPS / 10000;
            pool += t - rake;
            if (rake > 0) { totalRake += rake; emit RakeAccrued(rid, rake, totalRake); }
            r.state = 4;
        } else if (r.betCount < MIN_SMALL_BETS) {
            // <500 非决胜：90% 滚存 / 10% 运营费，不设普通奖。
            uint256 rake = t * RAKE_BPS / 10000;
            pool += t - rake;
            if (rake > 0) { totalRake += rake; emit RakeAccrued(rid, rake, totalRake); }
            r.state = 4;
        } else {
            // >=10~  非决胜：平台费先按固定10%计算；smallFund 20%-80%；所有整数尾差归 pool。
            // 这样平台绝不会因取整多收：平台费=floor(t*10%)，small=floor(t*20%~80%)，pool=剩余全部金额。
            uint256 rake = t * RAKE_BPS / 10000;
            small = t * SMALL_BPS / 10000;
            uint256 poolAdd = t - rake - small;
            pool += poolAdd;
            r.smallFund = small;              // 只能由链上固定公式产生，Operator 无法自由提交
            if (rake > 0) { totalRake += rake; emit RakeAccrued(rid, rake, totalRake); }
            r.state = 3;
        }
        emit SettlementDeclared(rid, bestDiff, champCount, circleCount, groupCount);
        emit ScanFinished(rid, bestDiff, champCount, circleCount, burst, t, small);   // 结算摘要事件；当前无链上逐注扫描
    }

    // ==================== 普通奖：64层 Sparse Merkle Settlement ====================
    /// @notice >=10~  注非决胜局一次提交完整普通奖结算承诺，替代逐 DIFF submitSmallGroups。
    /// @dev 正常路径只验证第一组 / cutoff组 / 最后一组三个 SMT 锚点 + 一笔真实 bestBet proof。
    ///      全量 DIFF 结果由公开数据 + settlementRoot 复核；异常通过挑战函数举证。
    function submitSmallSettlement(uint256 rid, SmallSettlementSubmission calldata s) external nonReentrant onlyOperator {
        Round storage r = rounds[rid];
        if (!(r.state == 3 && !r.burst && r.betCount >= MIN_SMALL_BETS)) revert WrongStateErr();
        if (!(s.root != bytes32(0))) revert ZeroSettlementRootErr();
        if (!(r.groupCount > 0)) revert NoGroupsErr();
        if (!(s.winnerGroupCount <= r.groupCount)) revert BadWinnerGroupsErr();

        uint256 cap = smallSlots(r.betCount);
        uint256 base = r.ticket * 101 / 100;
        if (!(r.smallFund >= base * cap)) revert SmallFundInvariantErr();
        if (!(s.smallWinners <= cap)) revert WinnerCapErr();
        if (!(s.smallPaid <= r.smallFund)) revert PaidExceedsFundErr();
        if (s.smallWinners == 0) {
            if (!(s.smallPaid == 0)) revert PaidWithoutWinnersErr();
        } else {
            if (!(s.smallPaid >= base * s.smallWinners)) revert PaidBelowBaseErr();
        }
        if (!(s.cutoffMode == CUTOFF_COLLISION || s.cutoffMode == CUTOFF_EXACT)) revert BadCutoffModeErr();

        // 三个锚点必须都真实属于同一个 SettlementRoot。
        if (!(_verifySmallWitness(s.root, rid, s.firstGroup))) revert BadFirstProofErr();
        if (!(_verifySmallWitness(s.root, rid, s.cutoffGroup))) revert BadCutoffProofErr();
        if (!(_verifySmallWitness(s.root, rid, s.lastGroup))) revert BadLastProofErr();

        // 第一组：必须与 settleDeclare 的 bestDiff/champCount 一致，且 prefix=0。
        if (!(s.firstGroup.value.groupIndex == 0)) revert FirstIndexErr();
        if (!(s.firstGroup.value.prefixBefore == 0)) revert FirstPrefixErr();
        if (!(s.firstGroup.diff == r.bestDiff)) revert FirstDiffErr();
        if (!(s.firstGroup.value.count == r.champCount)) revert FirstCountErr();

        // bestDiff 至少由一笔真实 BetRoot 注单锚定；若还存在更小 diff，proveFraud 可举证。
        bytes32 bestLeaf = _betLeaf(rid, s.bestBet.player, s.bestBet.guess, s.bestBet.nonce);
        if (!(_verifyProof(s.bestBet.proof, r.root, bestLeaf))) revert BadBestBetProofErr();
        if (!(_diff(s.bestBet.guess, r.settlePrice) == r.bestDiff)) revert BestBetDiffErr();

        // 最后一组必须闭合到 betCount。
        if (!(s.lastGroup.value.groupIndex + 1 == r.groupCount)) revert LastIndexErr();
        if (!(s.lastGroup.value.count > 0)) revert LastCountErr();
        if (!(s.lastGroup.value.prefixBefore <= r.betCount)) revert LastPrefixErr();
        if (!(s.lastGroup.value.count <= r.betCount - s.lastGroup.value.prefixBefore)) revert LastOverflowErr();
        if (!(s.lastGroup.value.prefixBefore + s.lastGroup.value.count == r.betCount)) revert BetCountClosureErr();

        // cutoff 锚点定义。
        if (!(s.cutoffGroup.diff == s.smallCutoff)) revert CutoffDiffErr();
        if (s.cutoffMode == CUTOFF_COLLISION) {
            // cutoff 自身是第一组 losing group；前缀赢家尚未满 cap，本组整组加入会超 cap。
            if (!(s.cutoffGroup.value.groupIndex == s.winnerGroupCount)) revert CollisionIndexErr();
            if (!(s.cutoffGroup.value.prefixBefore == s.smallWinners)) revert CollisionPrefixErr();
            if (!(s.smallWinners < cap)) revert CollisionWinnersErr();
            if (!(s.cutoffGroup.value.count > cap - s.smallWinners)) revert NoCollisionErr();
            if (!(s.cutoffGroup.value.outcome == SMALL_OUTCOME_LOSER)) revert CollisionOutcomeErr();
            if (!(s.cutoffGroup.value.tier == SMALL_TIER_NONE && s.cutoffGroup.value.amountEach == 0)) revert CollisionPrizeErr();
        } else {
            // cutoff 自身是最后一组 winner，并且这一组加入后恰好达到 cap。
            if (!(s.winnerGroupCount > 0)) revert NoWinnerGroupsErr();
            if (!(s.cutoffGroup.value.groupIndex + 1 == s.winnerGroupCount)) revert ExactIndexErr();
            if (!(s.cutoffGroup.value.prefixBefore <= cap)) revert ExactPrefixErr();
            if (!(s.cutoffGroup.value.count == cap - s.cutoffGroup.value.prefixBefore)) revert NotExactCapErr();
            if (!(s.smallWinners == cap)) revert ExactWinnersErr();
        }

        // 锚点本身的 winner/loser、tier、amount 必须能由链上公式复算。
        if (!(_smallGroupMatchesRules(r, s.firstGroup.diff, s.firstGroup.value, s.smallCutoff, s.cutoffMode, s.winnerGroupCount))) revert BadFirstGroupErr();
        if (!(_smallGroupMatchesRules(r, s.cutoffGroup.diff, s.cutoffGroup.value, s.smallCutoff, s.cutoffMode, s.winnerGroupCount))) revert BadCutoffGroupErr();
        if (!(_smallGroupMatchesRules(r, s.lastGroup.diff, s.lastGroup.value, s.smallCutoff, s.cutoffMode, s.winnerGroupCount))) revert BadLastGroupErr();

        r.settlementRoot = s.root;
        r.winnerGroupCount = s.winnerGroupCount;
        r.smallWinners = s.smallWinners;
        r.smallPaid = s.smallPaid;
        r.smallCutoff = s.smallCutoff;
        r.smallCutoffMode = s.cutoffMode;

        // 未派完普通奖基金继续滚入 pool；smallPaid 是公开结算数据的聚合摘要。
        pool += r.smallFund - s.smallPaid;
        r.state = 4;

        emit SmallSettlementCommitted(
            rid, s.root, r.groupCount, s.winnerGroupCount, s.smallWinners, s.smallPaid, s.smallCutoff, s.cutoffMode
        );
        emit SmallPrizesDone(rid, s.smallWinners, s.smallPaid);
    }

    /// @notice 决胜七级奖圈组提交：operator 按 diff 升序提交所有 diff<=CIRCLE_TOLERANCE 的申报圈组。
    /// @dev 仅 state 4 且 burst 可调用；必须恰好提交 circleGroups 个组，最终组 count 总和等于 circleCount。
    ///      若最佳差值在圈内，第一组必须满足 diff==bestDiff 且 count==champCount。
    ///      圈奖预算为当前总 pool 的 40%；冠军若在圈内可同时获得冠军份额与对应圈档份额。
    function submitCircleGroups(uint256 rid, uint64[] calldata diffs, uint256[] calldata counts) external nonReentrant onlyOperator {
        Round storage r = rounds[rid];
        if (!(r.state == 4 && r.burst)) revert WrongStateErr();
        uint256 gc = r.circleGroups;
        uint256 cur = r.burstRankCursor;
        if (!(cur < gc)) revert AlreadyRankedErr();
        if (!(diffs.length == counts.length && diffs.length > 0)) revert LengthMismatchErr();
        // 本批提交后不能超过 settleDeclare 申报的 circleGroups
        if (!(cur + diffs.length <= gc)) revert TooManyCircleGroupsErr();
        uint64 last = r.burstLastDiff;
        uint256 seq = r.burstTierSeq;

        for (uint256 i = 0; i < diffs.length; i++) {
            uint64 d = diffs[i];
            uint256 cnt = counts[i];
            if (!(cnt > 0)) revert ZeroCountErr();
            if (!(d <= CIRCLE_TOLERANCE)) revert NotCircleErr();  // 圈外组拒收（40% 只给 ±10U 内）
            if (!(_circleTierOf[rid][d] == 0)) revert DupGroupErr();
            if (!(d >= last)) revert NotSortedErr();
            // 最佳差值在 ±10U 圈内时，第一圈组必须与 bestDiff/champCount 完全一致。
            if (cur == 0 && r.bestDiff <= CIRCLE_TOLERANCE) {
                if (!(d == r.bestDiff)) revert ChampGroupFirstErr();
                if (!(cnt == r.champCount)) revert ChampCountMismatchErr();
            }
            last = d;
            (uint8 tier, ) = _tierOf(seq);                 // 档界与普通奖同一阶梯
            _circleTierOf[rid][d] = tier + 1;              // +1：0 保留给"未提交"
            _circleCountOf[rid][d] = cnt;                  // 该 diff 圈奖最多允许领取 cnt 次
            _burstTierBets[rid][tier] += cnt;
            emit BurstTierGroup(rid, cur, d, tier, cnt);
            seq++;
            cur++;
        }
        r.burstRankCursor = cur;
        r.burstLastDiff = last;
        r.burstTierSeq = seq;

        if (cur == gc) {
            // 所有已提交圈组的注数总和必须与 settleDeclare 的 circleCount 一致
            uint256 circleBets;
            for (uint8 k = 0; k < 7; k++) circleBets += _burstTierBets[rid][k];
            if (!(circleBets == r.circleCount)) revert CountSumErr();
            // 全部圈组到齐 → 锁定各档每注奖金：share_k = 预算×w_k / Σ(w_j×n_j)（向下取整）
            uint256 budget = pool * CIRCLE_BPS / 10000;    // 总池 40%（pool 已含本局90%，历史池不重复计提平台费）
            uint256 dsum;
            for (uint8 k = 0; k < 7; k++) dsum += uint256(BTIER_W[k]) * _burstTierBets[rid][k];
            uint256[7] memory shares;
            for (uint8 k = 0; k < 7; k++) {
                uint256 n = _burstTierBets[rid][k];
                if (n == 0) continue;
                uint256 share = budget * uint256(BTIER_W[k]) / dsum;
                _burstTierShare[rid][k] = share;
                shares[k] = share;
            }
            emit BurstPrizesRanked(rid, budget, shares);
        }
    }

    // ==================== 空局直结（0 注无需 Chainlink） ====================
    /// @notice 0 注轮次在 priceTime 后直接终结；不读取 Chainlink，也不使用 VRF。
    /// @dev 空局不属于周期有效轮：不增加 cycleRoundCount、不改变 pool/totalRake、不结束周期。
    ///      即使当前已经来到强制决胜位，空局也不会消耗该位置；强制决胜资格自动顺延到下一有下注轮。
    ///      ScanFinished 在这里仅作为统一结算摘要事件名使用，不表示发生了链上扫描。
    ///      settleInit 会拒绝空局，voidInit 的 state1 条件也要求 betCount>0，因此空局唯一终结入口就是本函数。
    function finalizeEmptyRound(uint256 rid) external nonReentrant {
        Round storage r = rounds[rid];
        if (!(r.state == 1)) revert WrongStateErr();
        if (!(r.betCount == 0)) revert NotEmptyErr();
        if (!(block.timestamp >= r.priceTime)) revert TooEarlyErr();

        r.bestDiff = type(uint64).max;      // 空局口径（无注可比）

        // 空局只结束当前时间格，不消耗周期有效轮数：
        // - cycleRoundCount 不变
        // - pool 不变
        // - totalRake 不变
        // - needNewCycle 不变
        // 因此如果 cycleRoundCount+1 已达到强制决胜条件，下一有注轮仍然会被判定为强制决胜。
        r.state = 5;

        emit ScanFinished(rid, r.bestDiff, 0, 0, false, 0, 0);
        emit RoundRolled(rid, cycleId, pool);
    }

    // ==================== 结算阶段三：最终性确认 / 决胜冠军份额锁定 ====================
    /// @notice state 4 的轮次进入经济最终状态；非决胜直接 Rolled，决胜锁定冠军每注份额。
    /// @dev finishAt 在入口写入，作为 10 分钟挑战窗口与 PHP 正式入账开放时间基准。
    ///      非决胜：state=5、cycleRoundCount+1、emit RoundRolled。
    ///      决胜：要求圈组已按 circleGroups 收齐；圈内有人时冠军预算60%，圈空时冠军预算100%，
    ///      按 champCount 向下取整得到 champShare，随后 state=6。
    function settleFinish(uint256 rid) external nonReentrant {
        Round storage r = rounds[rid];
        if (!(r.state == 4)) revert WrongStateErr();
        // settleFinish 是经济最终性边界：边界前 fraud 会阻止完成；边界后不再通过 void 回滚 pool/平台费。
        // 非决胜分支在此增加 cycleRoundCount；决胜分支不增加计数，而是在 settleDone 直接结束周期。
        if (!(!r.fraud)) revert FraudProvenErr();
        if (!(r.champCount > 0 || r.betCount == 0)) revert NoBetsErr();
        finishAt[rid] = uint64(block.timestamp);   // 挑战期起点；PHP 正式入账须等窗口结束

        if (!r.burst) {
            r.state = 5;
            // 非决胜有注轮在最终性边界处记为一个有效轮；后续挑战不会回退该计数。
            cycleRoundCount += 1;
            emit RoundRolled(rid, cycleId, pool);
            return;
        }
        if (!(r.champCount > 0)) revert NoChampErr();
        if (!(r.burstRankCursor == r.circleGroups)) revert CircleNotRankedErr();

        // 当前 pool 已包含历史滚存 + 本局90%；圈内有人时冠军预算60%，圈空时冠军预算100%。
        r.champShare = pool * (r.circleCount == 0 ? 10000 : CHAMP_BPS) / 10000 / r.champCount;
        r.state = 6;
    }
    
	/// @notice PHP/审计器判断本轮挑战窗口是否结束且未发现 fraud。
    /// @dev 普通局要求 state5；决胜局要求 state9。这里只给出链上可观察条件，不转移真实资金。
	/// @dev 普通奖挑战 5 分钟；决胜局挑战 10 分钟。
	function payoutReady(uint256 rid) public view returns (bool) {
		Round storage r = rounds[rid];
		if (r.fraud || finishAt[rid] == 0) {
			return false;
		}
		// 决胜轮挑战
		if (r.burst) {
			if (block.timestamp < finishAt[rid] + CHALLENGE_WINDOW) {
				return false;
			}
			return r.state == 9;
		}
		// 普通奖挑战
		if (block.timestamp < finishAt[rid] + SMALL_CHALLENGE_WINDOW) {
			return false;
		}
		return r.state == 5;
	}
    
    
    /// @notice 证明存在比 operator 申报 bestDiff 更小的合法下注。
    /// @dev proof 必须属于该轮 Merkle root，且实际 diff<r.bestDiff。
    ///      state 3/4 可直接举证；state 5/6/9 仅在 finishAt+CHALLENGE_WINDOW 前可举证。
    ///      边界前标记 fraud 后当前轮可 void；边界后同时 emit CompensationRequired 且不回滚已确认经济状态。
    ///      冠军人数少报不由本函数处理，使用 proveChampExcess。
    function proveFraud(uint256 rid, address player, uint64 guess, uint256 nonce, bytes32[] calldata proof) external nonReentrant {
        Round storage r = rounds[rid];
        if (!(r.betCount > 0)) revert EmptyRoundErr();
        if (!(!r.fraud)) revert FraudProvenErr();
        uint64 challengeWindow = r.burst? CHALLENGE_WINDOW: SMALL_CHALLENGE_WINDOW;   // 普通奖与决胜大奖轮 分开
        // state3/4 尚未越过最终性边界；state5/6/9 仅在各自 finishAt 挑战窗口内继续受理。
        if (!(r.state == 3 || r.state == 4 ||
            ((r.state == 5 || r.state == 6 || r.state == 9)
                && block.timestamp < finishAt[rid] + challengeWindow))) revert ChallengeClosedErr();
        bytes32 leaf = _betLeaf(rid, player, guess, nonce);
        if (!(_verifyProof(proof, r.root, leaf))) revert BadProofErr();
        uint64 diff = _diff(guess, r.settlePrice);
        // 本函数只处理“存在更小 diff”的申报错误；冠军人数少报由 proveChampExcess 单独处理。
        if (!(diff < r.bestDiff)) revert NoFraudErr();
        r.fraud = true;
        emit OperatorFraud(rid, leaf, r.bestDiff, diff);
        if (r.state == 5 || r.state == 6 || r.state == 9) emit CompensationRequired(rid);
    }

    /// @notice 冠军人数少报举证：逐个提交 diff==bestDiff 的不同合法 BetRoot leaf。
    /// @dev 普通局/决胜局均可使用；每个 leaf 只计一次，实证数量 > champCount 时标记 fraud。
    function proveChampExcess(uint256 rid, address player, uint64 guess, uint256 nonce, bytes32[] calldata proof) external nonReentrant {
        Round storage r = rounds[rid];
        if (!(r.betCount > 0)) revert EmptyRoundErr();
        if (!(!r.fraud)) revert FraudProvenErr();
        uint64 challengeWindow = r.burst? CHALLENGE_WINDOW: SMALL_CHALLENGE_WINDOW;   // 普通奖与决胜大奖轮 分开
        if (!(r.state == 3 || r.state == 4 ||
            ((r.state == 5 || r.state == 6 || r.state == 9) && block.timestamp < finishAt[rid] + challengeWindow))) revert ChallengeClosedErr();
        bytes32 leaf = _betLeaf(rid, player, guess, nonce);
        if (!(_verifyProof(proof, r.root, leaf))) revert BadProofErr();
        uint64 diff = _diff(guess, r.settlePrice);
        if (!(diff == r.bestDiff)) revert NotChampErr();
        if (!(!_champProofUsed[rid][leaf])) revert DupProofErr();
        _champProofUsed[rid][leaf] = true;
        uint256 n = ++_champProven[rid];
        emit ChampProven(rid, leaf, n);
        if (n > r.champCount) {
            r.fraud = true;
            emit OperatorFraud(rid, leaf, uint64(r.champCount), uint64(n));   // 字段口径：申报数 / 已举证数
            if (r.state == 5 || r.state == 6 || r.state == 9) emit CompensationRequired(rid);
        }
    }

    /// @notice 普通奖漏赢家举证：真实 Bet 按 cutoff 应中奖，但 Settlement SMT 对该 diff 给出 EMPTY。
    /// @dev 仅 >=10~  非决胜 state4/5；state5 只在挑战窗口内受理。
    function proveOmittedWinner(
        uint256 rid,
        address player,
        uint64 guess,
        uint256 nonce,
        bytes32[] calldata betProof,
        bytes32[64] calldata smtProof
    ) external nonReentrant {
        Round storage r = rounds[rid];
        if (!(!r.burst && r.betCount >= MIN_SMALL_BETS && (r.state == 4 || r.state == 5))) revert WrongStateErr();
        if (!(r.settlementRoot != bytes32(0))) revert NoSettlementRootErr();
        if (!(!r.fraud)) revert FraudProvenErr();
        if (r.state == 5) {
            if (!(block.timestamp < finishAt[rid] + SMALL_CHALLENGE_WINDOW)) revert ChallengeClosedErr();
        }

        bytes32 leaf = _betLeaf(rid, player, guess, nonce);
        if (!(_verifyProof(betProof, r.root, leaf))) revert BadBetProofErr();
        uint64 d = _diff(guess, r.settlePrice);
        if (!(_isWinnerRegion(d, r.smallCutoff, r.smallCutoffMode))) revert BeyondCutoffErr();
        if (!(_verifySmtEmpty(r.settlementRoot, d, smtProof))) revert GroupExistsErr();

        r.fraud = true;
        emit OperatorFraud(rid, leaf, r.smallCutoff, d);
        emit SettlementFraud(rid, 1, d);
        if (r.state == 5) emit CompensationRequired(rid);
    }

    /// @notice 证明 Settlement SMT 中某个已存在 group 的 prefix/outcome/tier/amount/cutoff 规则错误。
    /// @dev groupIndex>0 时必须同时提供前一 group 的合法 inclusion proof，以验证 prefix 连续性与 diff 严格递增。
    ///      hasPrev=false 仅允许用于 groupIndex==0。
    function proveBadSettlementGroup(
        uint256 rid,
        SmallGroupWitness calldata current,
        bool hasPrev,
        SmallGroupWitness calldata previous
    ) external nonReentrant {
        Round storage r = rounds[rid];
        if (!(!r.burst && r.betCount >= MIN_SMALL_BETS && (r.state == 4 || r.state == 5))) revert WrongStateErr();
        if (!(r.settlementRoot != bytes32(0))) revert NoSettlementRootErr();
        if (!(!r.fraud)) revert FraudProvenErr();
        if (r.state == 5) {
            if (!(block.timestamp < finishAt[rid] + SMALL_CHALLENGE_WINDOW)) revert ChallengeClosedErr();
        }
        if (!(_verifySmallWitness(r.settlementRoot, rid, current))) revert BadCurrentProofErr();

        bool bad = !_smallGroupMatchesRules(
            r, current.diff, current.value, r.smallCutoff, r.smallCutoffMode, r.winnerGroupCount
        );

        if (current.value.groupIndex == 0) {
            if (current.value.prefixBefore != 0) bad = true;
        } else {
            if (!(hasPrev)) revert PrevRequiredErr();
            if (!(_verifySmallWitness(r.settlementRoot, rid, previous))) revert BadPreviousProofErr();
            if (previous.value.groupIndex + 1 != current.value.groupIndex) bad = true;
            if (previous.diff >= current.diff) bad = true;
            if (previous.value.prefixBefore > type(uint256).max - previous.value.count) bad = true;
            else if (previous.value.prefixBefore + previous.value.count != current.value.prefixBefore) bad = true;
        }

        if (!(bad)) revert NoFraudErr();
        r.fraud = true;
        emit SettlementFraud(rid, 2, current.diff);
        if (r.state == 5) emit CompensationRequired(rid);
    }

    /// @notice 决胜周期收尾：按已锁定份额计算 champPaid/circlePaid，剩余值作为 fee，随后 pool 清零。
    /// @dev 仅 state 6 可调用，不等待挑战窗口；本局10%平台费已在 settleDeclare 计提。
    ///      settleDone 令 needNewCycle=true、state=9；挑战仍可在该轮 finishAt 窗口内继续，
    ///      PHP 正常入账仍必须等挑战窗口结束且 fraud==false。
    function settleDone(uint256 rid) external nonReentrant {
        Round storage r = rounds[rid];
        if (!(r.state == 6)) revert WrongStateErr();
        // settleFinish 已建立最终经济快照；这里仅按锁定份额做守恒收尾并开启新周期。
        // 若 state9 挑战窗口内随后坐实 fraud，不回滚本次收尾，而是冻结正常入账并转 CompensationRequired。
        uint256 champPaid = r.champShare * r.champCount;
        uint256 circlePaid;
        for (uint8 k = 0; k < 7; k++) circlePaid += _burstTierShare[rid][k] * _burstTierBets[rid][k];
        uint256 fee = pool - champPaid - circlePaid;
        emit BurstSettled(rid, cycleId, pool, champPaid, circlePaid, fee);
        pool = 0;
        needNewCycle = true;
        r.state = 9;
    }

    // ==================== 流局（退款） ====================
    // 流局原则：本轮所有有效下注 100% 退款，平台 10% 运营费也必须全部退回；本轮对 pool / totalRake 的临时影响归零。
    /// @notice 当前轮在 settleFinish 前满足指定故障条件时进入 Voiding(7)。
    /// @dev 条件包括：state0 锚根超时；state2 超过 VRF_GRACE/FINAL_GRACE；state1 非空局预言机死亡
    ///      或 anchoredAt+FINAL_GRACE；state3/4 超过 FINAL_GRACE；以及 state3/4 已证明 fraud。
    ///      state3/4 已发生临时拆账时先调用 _rollbackPreFinalAccounting；空局不满足 void 条件。
    function voidInit(uint256 rid, string calldata reason) external nonReentrant {
        Round storage r = rounds[rid];
        if (!(r.bettingClose != 0)) revert NoSuchRoundErr();
        if (!(rid == currentRoundId)) revert NotCurrentErr();
        if (!(r.state <= 4)) revert FinalizedErr();

        bool ok = false;
        if (r.fraud && (r.state == 3 || r.state == 4)) ok = true;
        if (r.state == 0 && block.timestamp > r.bettingClose + ROOT_GRACE) ok = true;
        if (r.state == 2 && block.timestamp > r.priceTime + VRF_GRACE) ok = true;
        if (r.state == 1 && r.betCount > 0 && _oracleDead()) ok = true;
        if (r.state == 1 && r.betCount > 0 && block.timestamp > r.anchoredAt + FINAL_GRACE) ok = true;
        if (r.state == 2 && block.timestamp > r.priceTime + FINAL_GRACE) ok = true;
        if ((r.state == 3 || r.state == 4) && block.timestamp > r.priceTime + FINAL_GRACE) ok = true;
        if (!(ok)) revert VoidConditionsNotMetErr();

        // 流局不收任何平台费：若已临时拆账，则把本轮 pool 与已临时计提的平台费全部回滚，PHP 再按下注台账 100% 退款。
        if (r.state == 3 || r.state == 4) _rollbackPreFinalAccounting(rid);

        r.state = 7;
        emit VoidStarted(rid, reason);
    }

    // 仅回滚本轮临时经济记账；执行后本轮对 pool / totalRake 的净影响应为 0。
    function _rollbackPreFinalAccounting(uint256 rid) internal {
        Round storage r = rounds[rid];
        uint256 t = r.totalBetAmount;
        uint256 poolBack = 0;
        uint256 rakeBack = 0;

        if (r.burst) {
            rakeBack = t * RAKE_BPS / 10000;
            poolBack = t - rakeBack;
        } else if (r.betCount < MIN_SMALL_BETS) {
            // <500 非决胜：90% pool / 10%平台费；流局时两部分全部回滚。
            rakeBack = t * RAKE_BPS / 10000;
            poolBack = t - rakeBack;
        } else {
            // >=10~ 非决胜：严格镜像 settleDeclare 的 Rake-First 口径。
            rakeBack = t * RAKE_BPS / 10000;
            uint256 small = t * SMALL_BPS / 10000;
            uint256 poolAdd = t - rakeBack - small;
            poolBack = poolAdd;
            if (r.state == 4 && r.settlementRoot != bytes32(0)) {
                // SettlementRoot 已提交时，未派 smallFund 已滚回 pool，一并撤销。
                poolBack += r.smallFund - r.smallPaid;
            }
        }

        if (!(pool >= poolBack && totalRake >= rakeBack)) revert RollbackMismatchErr();
        pool -= poolBack;
        totalRake -= rakeBack;
        emit PreFinalRollback(rid, poolBack, rakeBack);
    }


    /// @notice 完成流局状态切换 state 7→8；实际下注 100% 退款由 PHP 台账执行。
    function voidFinalize(uint256 rid) external nonReentrant {
        Round storage r = rounds[rid];
        if (!(r.bettingClose != 0)) revert NoSuchRoundErr();
        if (!(r.state == 7)) revert WrongStateErr();
        // state 7 只能在 settleFinish 前产生；链上临时账已回滚，实际每笔下注由 PHP 100% 退款（含原本的 10% 运营费）。
        r.state = 8;
        emit VoidFinalized(rid);
    }

    // ==================== 查询 / 公开复算 ====================
    // 合约不保存全量下注数组或全量 diff 组表；查询围绕 Merkle proof、锁定奖项和 Round 汇总状态展开。
    /// @notice 第一层自证：我这注被承诺了吗——proof 对锚定根验证（赢家输家通用）
    function verifyInclusion(
        uint256 rid, address player, uint64 guess, uint256 nonce, bytes32[] calldata proof
    ) external view returns (bool) {
        Round storage r = rounds[rid];
        bytes32 leaf = _betLeaf(rid, player, guess, nonce);
        return r.betCount > 0 && _verifyProof(proof, r.root, leaf);
    }

    /// @notice 验证某普通奖 Settlement Group 是否属于该轮 settlementRoot。
    function verifySmallGroup(uint256 rid, SmallGroupWitness calldata witness) external view returns (bool) {
        Round storage r = rounds[rid];
        return r.settlementRoot != bytes32(0) && _verifySmallWitness(r.settlementRoot, rid, witness);
    }

    /// @notice 验证某 diff 在普通奖 Settlement SMT 中确实为空（Non-Inclusion）。
    function verifySmallEmpty(uint256 rid, uint64 diff, bytes32[64] calldata siblings) external view returns (bool) {
        Round storage r = rounds[rid];
        return r.settlementRoot != bytes32(0) && _verifySmtEmpty(r.settlementRoot, diff, siblings);
    }

    /// @notice 返回与 V5.4 接近的轮次核心摘要，便于 Keeper/审计器读取。
    function getRoundAudit(uint256 rid) external view returns (
        bytes32 root, uint256 betCount, uint256 ticket, uint64 settlePrice, uint8 state,
        bool burst, uint64 bestDiff, uint256 champCount, uint256 circleCount,
        uint256 champShare, uint256 smallFund, uint256 totalBetAmount
    ) {
        Round storage r = rounds[rid];
        return (r.root, r.betCount, r.ticket, r.settlePrice, r.state, r.burst,
                r.bestDiff, r.champCount, r.circleCount, r.champShare, r.smallFund, r.totalBetAmount);
    }

    /// @notice V5.5 普通奖 SMT 结算摘要。
    function getSmallSettlementAudit(uint256 rid) external view returns (
        bytes32 settlementRoot, uint256 groupCount, uint256 winnerGroupCount,
        uint256 smallWinners, uint256 smallPaid, uint64 smallCutoff, uint8 cutoffMode, bool fraud
    ) {
        Round storage r = rounds[rid];
        return (r.settlementRoot, r.groupCount, r.winnerGroupCount, r.smallWinners,
                r.smallPaid, r.smallCutoff, r.smallCutoffMode, r.fraud);
    }

    /// @notice 查询指定决胜档位的每注圈奖份额。
    function getBurstTierShare(uint256 rid, uint8 tier) external view returns (uint256) {
        return _burstTierShare[rid][tier];
    }

    /// @notice 查询某 DIFF 的决胜圈档位；255 表示该 DIFF 未登记。
    function getCircleTier(uint256 rid, uint64 diff) external view returns (uint8) {
        uint8 t = _circleTierOf[rid][diff];
        return t == 0 ? type(uint8).max : t - 1;  // 255=未提交，0..6=实际圈奖档位
    }

    /// @notice PHP/其他实现可直接调用本函数得到协议规定的 SmallGroup valueHash。
    function hashSmallGroupValue(SmallGroupValue calldata value) external pure returns (bytes32) {
        return _smallGroupValueHash(value);
    }

    /// @notice 返回协议规定的非空 SMT leaf；绑定 chainId / contract / round / diff。
    function hashSmallGroupLeaf(uint256 rid, uint64 diff, SmallGroupValue calldata value) external view returns (bytes32) {
        return _smallGroupLeaf(rid, diff, _smallGroupValueHash(value));
    }

    /// @notice 返回第 level 层空子树哈希：level=0 为 EMPTY leaf，level=64 为整棵空 SMT root。
    function smtEmptyAt(uint8 level) external pure returns (bytes32 h) {
        if (!(level <= SMT_DEPTH)) revert BadLevelErr();
        h = _emptyLeaf();
        for (uint8 i = 0; i < level; i++) h = _hashSmtNode(h, h);
    }

    // ==================== 内部：档位 / 预言机 / Merkle ====================
    /// @notice 根据入选组序号 k 返回档位与普通奖 bonus 权重；第七档权重为 0
    function _tierOf(uint256 k) internal view returns (uint8 tier, uint16 w) {
        for (uint8 i = 0; i < 6; i++) {
            if (k < TIER_CUM[i]) return (i, TIER_W[i]);
        }
        return (6, 0);
    }

    /// @notice 对序号区间 [0,slots) 按 TIER_CUM/TIER_W 计算权重总和；第七档权重为 0
    function _weightSum(uint256 slots) internal view returns (uint256 ws) {
        uint256 lo;
        for (uint8 i = 0; i < 7; i++) {
            uint256 hi = i < 6 ? TIER_CUM[i] : slots;
            if (hi > slots) hi = slots;
            if (hi > lo) ws += (hi - lo) * TIER_W[i];
            lo = hi;
        }
    }

    /// @dev 按 V5 BetRoot 协议计算单笔下注 leaf。
    function _betLeaf(uint256 rid, address player, uint64 guess, uint256 nonce) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(rid, player, guess, nonce));
    }

    /// @dev 计算猜价与结算价的绝对差，单位为 0.0001 USD。
    function _diff(uint64 guess, uint64 settlePrice) internal pure returns (uint64) {
        return guess > settlePrice ? guess - settlePrice : settlePrice - guess;
    }

    /// @dev 按 SMT V1 协议计算普通奖 Group Value Hash。
    function _smallGroupValueHash(SmallGroupValue calldata value) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            value.groupIndex,
            value.count,
            value.prefixBefore,
            value.outcome,
            value.tier,
            value.amountEach
        ));
    }

    /// @dev 按 SMT V1 域分离规则计算普通奖非空叶子。
    function _smallGroupLeaf(uint256 rid, uint64 diff, bytes32 valueHash) internal view returns (bytes32) {
        return keccak256(abi.encode(
            bytes1(0x00),
            SMT_DOMAIN,
            block.chainid,
            address(this),
            rid,
            diff,
            valueHash
        ));
    }

    /// @dev 返回 SMT V1 的 EMPTY[0] 空叶哈希。
    function _emptyLeaf() internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(bytes1(0x02), SMT_DOMAIN));
    }

    /// @dev 按 SMT V1 Branch 域分离规则计算父节点哈希。
    function _hashSmtNode(bytes32 left, bytes32 right) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(bytes1(0x01), left, right));
    }

    /// @dev 验证普通奖 Group Witness 是否属于指定 SettlementRoot。
    function _verifySmallWitness(bytes32 root, uint256 rid, SmallGroupWitness calldata witness) internal view returns (bool) {
        bytes32 leaf = _smallGroupLeaf(rid, witness.diff, _smallGroupValueHash(witness.value));
        return _verifySmtLeaf(root, witness.diff, leaf, witness.siblings);
    }

    /// @dev 验证指定 uint64 key 在 64 层 SMT 中为 EMPTY。
    function _verifySmtEmpty(bytes32 root, uint64 key, bytes32[64] calldata siblings) internal pure returns (bool) {
        return _verifySmtLeaf(root, key, _emptyLeaf(), siblings);
    }

    /// @dev 沿 key 的 bit0→bit63 与 siblings 复算 64 层 SMT Root。
    function _verifySmtLeaf(bytes32 root, uint64 key, bytes32 leaf, bytes32[64] calldata siblings) internal pure returns (bool) {
        bytes32 h = leaf;
        for (uint8 i = 0; i < SMT_DEPTH; i++) {
            if (((uint256(key) >> i) & 1) == 0) h = _hashSmtNode(h, siblings[i]);
            else h = _hashSmtNode(siblings[i], h);
        }
        return h == root;
    }

    /// @dev 根据 cutoffMode 判断某 DIFF 是否位于普通奖赢家区域。
    function _isWinnerRegion(uint64 diff, uint64 cutoff, uint8 cutoffMode) internal pure returns (bool) {
        if (cutoffMode == CUTOFF_COLLISION) return diff < cutoff;
        if (cutoffMode == CUTOFF_EXACT) return diff <= cutoff;
        return false;
    }

    /// @dev 复算并校验普通奖 Group 的 outcome、tier 与 amountEach 是否符合链上规则。
    function _smallGroupMatchesRules(
        Round storage r,
        uint64 diff,
        SmallGroupValue calldata value,
        uint64 cutoff,
        uint8 cutoffMode,
        uint256 winnerGroupCount
    ) internal view returns (bool) {
        if (value.count == 0 || value.groupIndex >= r.groupCount) return false;
        if (value.prefixBefore > r.betCount) return false;
        if (value.count > r.betCount - value.prefixBefore) return false;

        uint256 cap = smallSlots(r.betCount);
        uint256 cumulative = value.prefixBefore + value.count;
        bool byCap = cumulative <= cap;
        bool byCutoff = _isWinnerRegion(diff, cutoff, cutoffMode);
        if (byCap != byCutoff) return false;

        if (byCutoff) {
            if (value.groupIndex >= winnerGroupCount) return false;
            if (value.outcome != SMALL_OUTCOME_WINNER) return false;
            (uint8 expectedTier, uint16 w) = _tierOf(value.groupIndex);
            if (value.tier != expectedTier) return false;

            uint256 base = r.ticket * 101 / 100;
            if (r.smallFund < base * cap) return false;
            uint256 bonusPool = r.smallFund - base * cap;
            uint256 wsum = _weightSum(cap);
            uint256 expectedAmount = base + (w == 0 ? 0 : bonusPool * uint256(w) / wsum / value.count);
            if (value.amountEach != expectedAmount) return false;
        } else {
            if (value.groupIndex < winnerGroupCount) return false;
            if (value.outcome != SMALL_OUTCOME_LOSER) return false;
            if (value.tier != SMALL_TIER_NONE || value.amountEach != 0) return false;
        }
        return true;
    }

    /// @dev 判断 Chainlink Feed 是否异常或最新价格超过 ORACLE_STALE。
    function _oracleDead() internal view returns (bool) {
		try feed.latestRoundData() returns (
			uint80,
			int256 answer,
			uint256,
			uint256 updatedAt,
			uint80
		) {
			// 无效价格、无时间戳、未来时间戳均视为 Oracle 异常
			if (answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp) {
				return true;
			}

			return block.timestamp - updatedAt > ORACLE_STALE;
		} catch {
			return true;
		}
	}

	/// @notice 读取 operator 提交的 Chainlink roundId，并验证其为
	///         target 时刻“不晚于 target 的最后一个 Tick”。
	/// @dev 验证规则：
	///      candidate.updatedAt <= target
	///      next.updatedAt > target
	///      因此 candidate 被严格夹在目标时间之前，而下一 Tick 已跨过目标时间，
	///      operator 无法故意选择更早的历史报价。
	///      注意：必须等 candidate 的下一 Chainlink Round 已产生后才能完成验证。
	function _priceAt(uint80 oracleRoundId,uint64 target) internal view returns (uint64) {
		// ============================================================
		// 1. 读取 PHP 提交的候选 Round
		// ============================================================
		(
			uint80 returnedRoundId,
			int256 answer,
			,
			uint256 updatedAt,
			uint80 answeredInRound
		) = feed.getRoundData(oracleRoundId);
		// ============================================================
		// 2. candidate 本身必须有效
		// ============================================================
		if (!(returnedRoundId == oracleRoundId))
			revert NoDataAtRoundErr();
		if (!(updatedAt > 0))
			revert NoDataAtRoundErr();
		if (!(answer > 0))
			revert BadAnswerErr();
		// ============================================================
		// 3. candidate 不能晚于目标结算时间
		// 例如：
		// target    = 12:10:00
		// candidate = 12:09:57     ✓
		// candidate = 12:10:00     ✓
		// candidate = 12:10:01     ×
		// ============================================================
		if (!(updatedAt <= target))
			revert PriceAfterTargetErr();
		// ============================================================
		// 4. candidate 不能离目标时间太久
		// 保留原来的 ORACLE_STALE 防护。
		// ============================================================
		if (!(uint256(target) - updatedAt < ORACLE_STALE))
			revert StalePriceErr();

		// 5. 读取 candidate 的下一 Chainlink Round
		// 正常同一 Chainlink phase 内：
		// nextRoundId = oracleRoundId + 1
		// 如果下一 Tick 尚未产生，getRoundData 会失败；
		// Keeper 稍后再次调用 settleInit 即可。
		uint80 nextRoundId = oracleRoundId + 1;

		(
			uint80 nextReturnedRoundId,
			,
			,
			uint256 nextUpdatedAt,
		) = feed.getRoundData(nextRoundId);

		// 6. 下一 Round 必须真实存在
		if (!(nextReturnedRoundId == nextRoundId))
			revert NoDataAtRoundErr();
		if (!(nextUpdatedAt > 0))
			revert NoDataAtRoundErr();

		// ============================================================
		// 7. 最关键验证：
		// 下一 Tick 必须已经严格超过 target。
		// candidate <= target < next
		// 才能证明 candidate 就是 target 前最后一个 Tick。
		if (!(nextUpdatedAt > target))
			revert NextRoundNotAfterTargetErr();

		// ============================================================
		// 8. 返回最终结算价格
		// ============================================================
		return _toPriceUnit(answer);
	}    

    /// @notice 8位小数 → 3位小数（毫位），四舍五入
    function _toMillis(int256 answer) internal pure returns (uint64) {
        return uint64((uint256(answer) + 5e4) / 1e5);
    }

	/// @notice Chainlink 8位小数 → 4位小数（0.0001 USD 单位），四舍五入
	function _toPriceUnit(int256 answer) internal pure returns (uint64) {
		return uint64((uint256(answer) + 5e3) / 1e4);
	}

    /// @dev 验证 V5 BetRoot 使用的 sorted-pair Merkle Proof。
    function _verifyProof(bytes32[] calldata proof, bytes32 root, bytes32 leaf) internal pure returns (bool) {
        bytes32 h = leaf;
        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 p = proof[i];
            h = h < p ? keccak256(abi.encodePacked(h, p)) : keccak256(abi.encodePacked(p, h));
        }
        return h == root;
    }
}
