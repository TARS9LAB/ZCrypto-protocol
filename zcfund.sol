// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

// ============ Chainlink ============
// ============ 预言机接口（Chainlink V3 Aggregator） ============
interface AggregatorV3Interface {
    function latestRoundData() external view returns (
        uint80, int256, uint256, uint256, uint80
    );

    function decimals() external view returns (uint8);
}

// ============ Pancake V3 Router 接口 ============
interface IPancakeV3Router {
    // 单路径兑换参数结构体
    struct ExactInputSingleParams {
        address tokenIn;             // 输入代币
        address tokenOut;            // 输出代币
        uint24 fee;                  // 手续费档位（100/500/2500/10000）
        address recipient;           // 接收人地址
        uint256 deadline;            // 交易截止时间
        uint256 amountIn;            // 输入金额
        uint256 amountOutMinimum;    // 最少输出金额（防滑点保护）
        uint160 sqrtPriceLimitX96;   // 价格限制（一般填 0 表示无）
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
    external
    payable
    returns (uint256 amountOut); // 返回实际换出的 token 数量
}

// ============ Pancake V3 QuoterV2 接口 ============
// 用于链下/链上预估某笔交易大概能换多少
interface IPancakeQuoterV2 {
    struct QuoteExactInputSingleParams {
        address tokenIn;             // 输入代币
        address tokenOut;            // 输出代币
        uint256 amountIn;            // 输入金额
        uint24 fee;                 // 手续费档位
        uint160 sqrtPriceLimitX96;   // 价格限制
    }

    function quoteExactInputSingle(
        QuoteExactInputSingleParams calldata params
    )
    external
    returns (
        uint256 amountOut,       // 预估输出
        uint160 sqrtPriceX96After,
        uint32 initializedTicksCrossed,
        uint256 gasEstimate      // gas 估算
    );
}

// ============ 主合约：FancyBTC_CommitmentVault ============
contract FancyBTC is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20Metadata;

    // ------- 核心依赖 -------
    IERC20Metadata public immutable USDT;    // USDT 合约
    address public  DIVIDEND;                // 分红 合约
    IPancakeV3Router public  router;         // Pancake V3 路由器
    IPancakeQuoterV2 public  quoter;         // Pancake V3 报价器

    // ------- 费用参数（1e18 = 100%） -------
    uint256 public performanceFeeRate = 1000;          // 业绩报酬费率 （百分之10 1000/10000）
    uint256 public redemptionFeeRate = 50;
    uint256 public minDepositUSDT = 10 * 10 ** 18; // 最小存款 = 10 USDT; 最小存入金额
    uint256 public max_allowed_slippage_bps = 500; // 最大允许5%滑点（可按需调整）

    mapping(address => uint256) public userDepositBalanceList; // 存款列表
    mapping(address => Lot) public userLot; // 价值列表
    address[4] public  tokens;
    address[4] public  priceFeeds;

    // ------- 预言机保护参数 -------
    bool    public oracleGuardEnabled = true;         // 是否启用预言机保护
    uint256 public oracleStaleAfter = 2 hours;   // 预言机数据过期时间
    uint256 public oracleMaxDeviationBps = 100;       // 最大允许偏差（BPS，100=1%）
    mapping(address => mapping(bytes32 => uint256)) public userLimitPriceList; // 用户限价计划
    mapping(address => bool) public devList;     // 存款列表

    struct BuyParams {
        uint256 amountUSDT;
        uint24 poolFee;
        uint256 slippageBps;
        uint256 quoted;
        address token;
        uint256 exPrice;
    }
    // ------- 存款批次结构 -------
    struct Lot {
        uint256 btc;        // btc数量
        uint256 wbnb;        // bnb数量
        uint256 eth;        // eth数量
        uint256 aster;      // aster数量
    }

    // ------- 事件 -------
    event DepositCommitment(
        address indexed user,     // 用户
        uint256 indexed num,     // 存入数量
        address indexed token,  // 代币
        uint256 price,           // 价格
        uint256 amount
    );
    //提现事件
    event WithdrawEvent(
        address indexed user,     // 用户
        uint256 indexed num,     // 赎回数量
        address indexed token,  // 代币
        uint256 price,           // 价格
        uint256 amount
    );
    event LimitQueue(
        address indexed user,     // 用户
        uint256 indexed amount,   // 限价金额
        bytes32 indexed orderId, // 订单ID
        uint256 _type // 类型 限价买入 限价卖出 限价取消
    );

    //触发赎回手续费事件
    event FeeEvent(address indexed c, uint256 indexed managementFee, uint256 tax);

    // ------- 构造函数 -------
    constructor(
        address initialOwner // 初始合约拥有者
    ) Ownable(initialOwner) {

        address _usdt = 0x55d398326f99059fF775485246999027B3197955;
        address _router = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
        address _quoter = 0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997;

        // 设置依赖
        USDT = IERC20Metadata(_usdt);
        router = IPancakeV3Router(_router);
        quoter = IPancakeQuoterV2(_quoter);

        tokens[0] = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c; // btc
        tokens[1] = 0x2170Ed0880ac9A755fd29B2688956BD959F933F8; // eth
        tokens[2] = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c; // wbnb
        tokens[3] = 0x000Ae314E2A2172a039B26378814C252734f556A; // aster

    }

    // 限价存入合约，等待时机成交
    function enterPriceLimitQueue(uint256 amount, bytes32 orderId) external whenNotPaused nonReentrant {
        address user = msg.sender;
        require(amount >= minDepositUSDT, "amount<minDeposit");  // 金额必须大于最小存款限制
        require(userLimitPriceList[user][orderId] == 0, "existence");

        uint256 before = USDT.balanceOf(address(this));
        USDT.safeTransferFrom(user, address(this), amount);
        uint256 received = USDT.balanceOf(address(this)) - before;
        require(received == amount, "fee-on-transfer");

        userLimitPriceList[user][orderId] = amount;
        emit LimitQueue(user, amount, orderId, 1);
    }
    // 取消限价买入
    function cancelEnterPriceLimitQueue(bytes32 orderId) external whenNotPaused nonReentrant {
        address user = msg.sender;
        uint256 amount = userLimitPriceList[user][orderId];
        require(amount > 0, "order not exist");
        userLimitPriceList[user][orderId] = 0;
        USDT.safeTransfer(user, amount);
        emit LimitQueue(user, amount, orderId, 3);
    }
    // 脚本执行 限价买入
    function swapBuyPrice(
        uint256 expectationPrice, // 期望价格
        address[] calldata users, // 用户列表
        bytes32[] calldata orderIds, // 订单ID列表
        uint256[] calldata amounts,   // 存款列表
        uint256 slippageBps,  // 用户可容忍的滑点（基点，1%=100）
        uint256[] calldata rates // 兑换比例列表
    )
    external whenNotPaused nonReentrant {
        address sender = msg.sender;
        uint256 total;

        require(users.length == amounts.length, "users.length != amounts.length");
        require(users.length == orderIds.length, "users.length != orderIds.length");
        require(devList[sender], "no op");
        require(expectationPrice > 0, "no expectationPrice");
        require(slippageBps <= max_allowed_slippage_bps, "slippage>5%"); // 最大滑点限制为 5%
        require(rates.length == tokens.length, "invalid rates len");
        for (uint256 i; i < rates.length; i++) {
            total += rates[i];
        }
        require(total == 10000, "rates != 100%");

        for (uint256 i; i < users.length; i++) {
            address u = users[i];
            bytes32 orderId = orderIds[i];
            require(amounts[i] > 0, "order not exist");
            require(amounts[i] <= userLimitPriceList[u][orderId], "amount error");
            userLimitPriceList[u][orderId] = 0;
        }

        for (uint256 i; i < users.length; i++) {
            priceLimitDepositWithCommitment(
                expectationPrice,
                users[i],
                amounts[i],
                slippageBps,
                rates
            );
        }
    }
    // 脚本执行限制卖出
    function swapSellPrice(
        uint256 expectationPrice, // 期望价格
        address[] calldata users, // 用户列表
        uint256[] calldata tokenNumberList,   // 赎回代币数量
        uint256 slippageBps,  // 用户可容忍的滑点（基点，1%=100）
        uint24 poolFee        // Pancake V3 交易池费率（100/500/2500/10000）
    )
    external whenNotPaused nonReentrant {
        address sender = msg.sender;
        require(devList[sender], "no op");
        require(expectationPrice > 0, "no expectationPrice");
        require(slippageBps <= max_allowed_slippage_bps, "slippage>5%");// 最大滑点限制为5%（你的硬性底线）
        require(
            poolFee == 100 || poolFee == 500 || poolFee == 2500 || poolFee == 10000,
            "invalid poolFee" // 检查池子费率是否合法
        );
        require(users.length == tokenNumberList.length, "users.length != amounts.length");
        for (uint256 i; i < users.length; i++) {
            Lot storage lotS = userLot[users[i]];
            uint256 tokenNum = getUserTokenNum(tokens[0], lotS); // btc的数量
            require(tokenNum > 0, "tokenNum=0");
            require(tokenNumberList[i] > 0, "amount=0");
            require(tokenNumberList[i] <= tokenNum, "insufficient btc");
            uint256 redemptionRate = tokenNumberList[i] * 10000 / tokenNum;
            if (redemptionRate > 9800) {
                redemptionRate = 10000;
            }
            priceLimitWithdrawPartialCommitment(expectationPrice, users[i], redemptionRate, slippageBps, poolFee);
        }
    }

    // ========================
    // ====== 限价存入 ============
    // ========================
    function priceLimitDepositWithCommitment(
        uint256 expectationPrice,
        address user,
        uint256 amount,   // 存款的 USDT 数量
        uint256 slippageBps,  // 用户可容忍的滑点（基点，1%=100）
        uint256[]  calldata rates // 兑换比例列表
    )
    internal
    {
        uint256 remaining = amount;
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 _amountUSDT;
            if (i == tokens.length - 1) {
                _amountUSDT = remaining;
            } else {
                _amountUSDT = amount * rates[i] / 10000;
                remaining -= _amountUSDT;
            }
            _executeBuy(
                user,
                amount,
                _amountUSDT,
                slippageBps,
                500,
                tokens[i],
                expectationPrice
            );
        }
        userDepositBalanceList[user] += amount;
    }

    // ========================
    // ====== 存入 ============
    // ========================
    function depositWithCommitment(
        uint256 amount,   // 存款的 USDT 数量
        uint256 slippageBps,  // 用户可容忍的滑点（基点，1%=100）
        uint24 poolFee,        // Pancake V3 交易池费率（100/500/2500/10000）
        uint256[]  calldata rates // 兑换比例列表
    )
    external whenNotPaused nonReentrant
    {
        uint256 len = tokens.length;
        address user = msg.sender;
        // ---- 基础校验 ----
        require(amount >= minDepositUSDT, "amount<minDeposit");  // 金额必须大于最小存款限制
        require(slippageBps <= max_allowed_slippage_bps, "slippage>5%"); // 最大滑点限制为 5%
        require(rates.length == len, "invalid rates len");

        uint256 total;
        for (uint i; i < len; i++) {
            total += rates[i];
        }
        require(total == 10000, "rates != 100%");

        require(
            poolFee == 100 || poolFee == 500 || poolFee == 2500 || poolFee == 10000,
            "invalid poolFee"
        );  // 只允许 Pancake V3 的合法费档
        // ---- 转账 USDT ----
        uint256 before = USDT.balanceOf(address(this));
        USDT.safeTransferFrom(user, address(this), amount);
        uint256 afterBalance = before + amount;
        require(USDT.balanceOf(address(this)) == afterBalance, "fee-on-transfer");
        uint256 remaining = amount;
        for (uint256 i = 0; i < len; i++) {

            uint256 _amountUSDT;

            if (i == len - 1) {
                _amountUSDT = remaining;
            } else {
                _amountUSDT = amount * rates[i] / 10000;
                remaining -= _amountUSDT;
            }
            _executeBuy(
                user,
                amount,
                _amountUSDT,
                slippageBps,
                poolFee,
                tokens[i],
                0
            );
        }
        userDepositBalanceList[user] += amount;
    }

    function _executeBuy(
        address user,
        uint256 amount,
        uint256 _amountUSDT,
        uint256 slippageBps,
        uint24 poolFee,
        address token,
        uint256 exPrice
    ) internal {
        uint256 quoted = _estimatedDoUsdtToToken(_amountUSDT, poolFee, token);
        BuyParams memory bp = BuyParams({
            amountUSDT: _amountUSDT,
            poolFee: poolFee,
            slippageBps: slippageBps,
            quoted: quoted,
            token: token,
            exPrice: exPrice
        });

        (uint256 outNum, uint256 price) = _buyFundCommitment(bp);
        _setAddTokenNum(token, outNum, userLot[user]);
        emit DepositCommitment(user, outNum, token, price, amount);
    }

    function _estimatedDoUsdtToToken(uint256 _amountUSDT, uint24 poolFee, address _BTCB) internal returns (uint256)  {
        // ---- 向 Pancake Quoter 查询报价 ----
        IPancakeQuoterV2.QuoteExactInputSingleParams memory qparams =
                            IPancakeQuoterV2.QuoteExactInputSingleParams({
                tokenIn: address(USDT),      // 输入 USDT
                tokenOut: _BTCB,     // 兑换 token数量
                amountIn: _amountUSDT,        // 兑换数量
                fee: poolFee,               // 费档
                sqrtPriceLimitX96: 0         // 不设价格限制
            });

        uint256 quoted;
        try quoter.quoteExactInputSingle(qparams)
        returns (uint256 amountOut, uint160, uint32, uint256)
        {
            quoted = amountOut;              // 预估可兑换的 BTCB 数量
        } catch (bytes memory reason) {
            if (reason.length == 0) {
                revert("Quoter failed: error)");
            } else {
                // 把 Quoter 原始错误直接抛出来，前端能看到真实原因
                assembly {
                    revert(add(reason, 32), mload(reason))
                }
            }
        }
        require(quoted > 0, "quote=0");// 报价必须大于 0
        return quoted;
    }

    // 开始购买基金
    function _buyFundCommitment(BuyParams memory p)
    internal
    returns (uint256, uint256)
    {
        uint256 minOut = (p.quoted * (10_000 - p.slippageBps)) / 10_000;

        _ensureAllowance(USDT, address(router), p.amountUSDT);

        IPancakeV3Router.ExactInputSingleParams memory params =
                            IPancakeV3Router.ExactInputSingleParams({
                tokenIn: address(USDT),
                tokenOut: p.token,
                fee: p.poolFee,
                recipient: address(this),
                deadline: block.timestamp + 300,
                amountIn: p.amountUSDT,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            });

        uint256 out = router.exactInputSingle(params);

        if (oracleGuardEnabled) {
            AggregatorV3Interface pf = _getPriceFeed(p.token);
            uint256 oracleFloor = _oracleMinBtcOutForUsdt(p.amountUSDT, pf);
            require(out >= oracleFloor, "actual < oracle floor");
        }

        uint256 price = (p.amountUSDT * 1e18) / out;

        if (p.exPrice > 0 && price > p.exPrice) {
            require(
                price <= p.exPrice * (10_000 + p.slippageBps) / 10_000,
                "Exceeding the expected price"
            );
        }

        return (out, price);
    }

    // ========================
    // ===== 限价部分赎回 =========
    // ========================
    function priceLimitWithdrawPartialCommitment(
        uint256 expectationPrice,
        address recipient,
        uint256 redemptionRate,  // 本次要赎回的百分之比（100 = 1%，1000 <=x<= 10000,10%<=x<=100%）
        uint256 slippageBps,     // 滑点容忍度（基点，100=1%）
        uint24 poolFee           // Pancake V3 交易池费率（100/500/2500/10000）
    ) internal {
        uint256 len = tokens.length;

        Lot storage lotS = userLot[recipient];
        uint256 _value = 0;
        uint256 expectedUsdt = (userDepositBalanceList[recipient] * redemptionRate) / 10000;
        for (uint256 i = 0; i < len; i++) {
            uint256 tokenNum = getUserTokenNum(tokens[i], lotS);
            // 计算要卖掉的token数量
            uint256 sellTokenNum = (tokenNum * redemptionRate) / 10000;
            if (sellTokenNum == 0) {
                continue;
            }
            uint256 _outUsdt = _userWithdraw(recipient, slippageBps, poolFee, sellTokenNum, tokens[i]);
            _value = _value + _outUsdt;
            _setDecTokenNum(tokens[i], sellTokenNum, lotS);
            // 触发赎回事件
            uint256 _price = (_outUsdt * 1e18) / sellTokenNum;

            if (address(tokens[i]) == address(tokens[0])) {
                // 卖出只判断价格没有达到预期的情况，如果价格更高无条件卖出
                if (_price < expectationPrice) {
                    // 如果实际价格小于预期价格，看看是不是满足滑点
                    require(_price >= expectationPrice * (10_000 - slippageBps) / 10_000, "Exceeding the expected price");
                }
            }
            emit WithdrawEvent(recipient, sellTokenNum, tokens[i], _price, expectedUsdt);
        }
        calculateProfitFee(_value, recipient, redemptionRate);
    }

    // ========================
    // ===== 部分赎回 =========
    // ========================
    function withdrawPartialCommitment(
        uint256 redemptionRates,  // 本次要赎回的百分之比（100 = 1%，1000 <=x<= 10000,10%<=x<=100%）
        uint256 slippageBps,     // 滑点容忍度（基点，100=1%）
        uint24 poolFee           // Pancake V3 交易池费率（100/500/2500/10000）
    ) external whenNotPaused nonReentrant {
        address recipient = msg.sender;
        uint256 len = tokens.length;
        require(redemptionRates >= 1000 && redemptionRates <= 10000, "Redemption Rates < 10%");// 必须赎回大于等于百分之10的份额
        require(slippageBps <= max_allowed_slippage_bps, "slippage>5%");                // 最大滑点限制为5%（你的硬性底线）

        require(
            poolFee == 100 || poolFee == 500 || poolFee == 2500 || poolFee == 10000,
            "invalid poolFee"                                      // 检查池子费率是否合法
        );
        Lot storage lotS = userLot[recipient];
        uint256 _value = 0;
        uint256 sellUsdt = (userDepositBalanceList[recipient] * redemptionRates) / 10000;
        for (uint256 i = 0; i < len; i++) {
            uint256 tokenNum = getUserTokenNum(tokens[i], lotS);
            // 计算要卖掉的btc数量
            uint256 sellTokenNum = (tokenNum * redemptionRates) / 10000;
            if (sellTokenNum == 0) {
                continue;
            }
            uint256 _outUsdt = _userWithdraw(recipient, slippageBps, poolFee, sellTokenNum, tokens[i]);
            _value = _value + _outUsdt;
            _setDecTokenNum(tokens[i], sellTokenNum, lotS);
            // 触发赎回事件
            uint256 _price = (_outUsdt * 1e18) / sellTokenNum;
            emit WithdrawEvent(recipient, sellTokenNum, tokens[i], _price, sellUsdt);
        }
        calculateProfitFee(_value, recipient, redemptionRates);
    }


    function _doSwapExactBtcForUsdt(
        uint256 btcToSell, // 卖出的BTCB数量
        uint256 slippageBps,
        uint24 poolFee,
        address _token
    ) internal returns (uint256 redeemedUSDT) {
        // ---- 基础安全校验 ----
        // 要求卖出数量不能过小，避免dust交易造成失败或浪费gas
        uint8 d = IERC20Metadata(_token).decimals();
        require(btcToSell >= 10 ** (d - 6), "amountIn too small");

        // ---- 使用 Quoter 模拟询价，预估兑换结果 ----
        IPancakeQuoterV2.QuoteExactInputSingleParams memory qparams =
                            IPancakeQuoterV2.QuoteExactInputSingleParams({
                tokenIn: _token,          // 输入代币：BTCB
                tokenOut: address(USDT),         // 输出代币：USDT
                amountIn: btcToSell,             // 卖出的BTCB数量
                fee: poolFee,                    // 交易池费率
                sqrtPriceLimitX96: 0             // 不设置价格限制
            });

        uint256 quoted;
        try quoter.quoteExactInputSingle(qparams)
        returns (uint256 amountOut, uint160, uint32, uint256)
        {
            quoted = amountOut;                  // 预估能兑换得到的USDT
        } catch {
            revert("Quoter failed for BTCB to USDT swap");
        }
        require(quoted > 0, "quote=0");          // 确保有有效报价

        // ---- 计算最小可接受USDT数量（滑点 + 预言机双重保护） ----
        // 按用户设置的最大滑点折扣，计算最低可接受输出
        uint256 minUsdtOut = (quoted * (10_000 - slippageBps)) / 10_000;
        if (oracleGuardEnabled) {
            // 基于预言机，计算相同输入btcToSell下应得到的最低USDT（带安全系数）
            AggregatorV3Interface _priceFeed = _getPriceFeed(_token);
            uint256 floorByOracle = _oracleMinUsdtOutForBtc(btcToSell, _priceFeed);
            if (floorByOracle > minUsdtOut) {
                // 取预言机下限作为最终保护
                minUsdtOut = floorByOracle;
            }
        }
        // ---- 授权路由合约使用BTCB ----
        _ensureAllowance(IERC20Metadata(_token), address(router), btcToSell);

        // 构造实际swap参数
        IPancakeV3Router.ExactInputSingleParams memory params =
                            IPancakeV3Router.ExactInputSingleParams({
                tokenIn: _token,          // 输入：BTCB
                tokenOut: address(USDT),         // 输出：USDT
                fee: poolFee,                    // 使用的费率档位
                recipient: address(this),        // 收款地址=当前合约
                deadline: block.timestamp + 300, // 交易有效期=当前时间+5分钟
                amountIn: btcToSell,             // 精确卖出的BTCB数量
                amountOutMinimum: minUsdtOut,    // 防滑点保护：最少能得到的USDT
                sqrtPriceLimitX96: 0             // 不设置价格限制
            });
        // ---- 执行实际swap ----
        uint256 swapOut = router.exactInputSingle(params);
        // 校验兑换结果满足最低要求
        require(swapOut >= minUsdtOut, "swap output below minimum due to slippage");
        return swapOut;
    }

    // 某种原因管理员帮助用户赎回存款
    function helpUserRedeem(
        address recipient,       // 赎回资金接收人
        uint256 redemptionRates,  // 本次要赎回的百分之比（100 = 1%，1000 <=x<= 10000,10%<=x<=100%）
        uint256 slippageBps,     // 滑点容忍度（基点，100=1%）
        uint24 poolFee           // Pancake V3 交易池费率（100/500/2500/10000）
    ) external onlyOwner {
        uint256 len = tokens.length;
        require(recipient != address(0), "recipient=0");           // 接收人不能为空，防止资金打入黑洞
        require(redemptionRates >= 1000 && redemptionRates <= 10000, "Redemption Rates < 10%");                   // 必须赎回大于等于百分之10的份额
        require(slippageBps <= 200, "slippage>2%");                // 最大滑点限制为2%（你的硬性底线）
        require(
            poolFee == 100 || poolFee == 500 || poolFee == 2500 || poolFee == 10000,
            "invalid poolFee"                                      // 检查池子费率是否合法
        );
        Lot storage lotS = userLot[recipient];
        uint256 _value = 0;
        uint256 sellUsdt = (userDepositBalanceList[recipient] * redemptionRates) / 10000;
        for (uint256 i = 0; i < len; i++) {
            uint256 tokenNum = getUserTokenNum(tokens[i], lotS);
            // 计算要卖掉的btc数量
            uint256 sellTokenNum = (tokenNum * redemptionRates) / 10000;
            // 跳过过小仓位，避免 DoS
            if (sellTokenNum == 0) {
                continue;
            }
            uint256 _outUsdt = _userWithdraw(recipient, slippageBps, poolFee, sellTokenNum, tokens[i]);
            _value = _value + _outUsdt;
            _setDecTokenNum(tokens[i], sellTokenNum, lotS);
            // 触发赎回事件
            uint256 _price = (_outUsdt * 1e18) / sellTokenNum;
            emit WithdrawEvent(recipient, sellTokenNum, tokens[i], _price, sellUsdt);
        }
        calculateProfitFee(_value, recipient, redemptionRates);
    }

    function _userWithdraw(
        address recipient, // 领取人
        uint256 slippageBps, // 滑点
        uint24 poolFee, // 兑换手续费
        uint256 sellTokenNum, // 出售代币数量
        address _token
    ) internal returns (uint256) {

        // 预计获得usdt数量
        uint256 redeemedUsdt = _doSwapExactBtcForUsdt(sellTokenNum, slippageBps, poolFee, _token);

        return redeemedUsdt;
    }

    // 计算管理费
    function calculateProfitFee(uint256 _value, address user, uint256 _rate) internal {
        if (_value == 0) return;

        uint256 totalRateValue = (userDepositBalanceList[user] * _rate) / 10000; // 计算本金

        uint256 redemptionValue = (_value * redemptionFeeRate) / 10000; // 从获得的usdt中抽取管理费
        _value = _value - redemptionValue;

        uint256 tax = 0;
        if (totalRateValue < _value) { // 计算剩下的金额是否盈利
            uint256 cost = _value - totalRateValue;
            if (cost > 0) {
                tax = tax + (cost * performanceFeeRate) / 10000; // 盈利费用
            }
        }

        // 1) 安全地减少用户的 deposit balance —— 取 min
        uint256 toSub = totalRateValue;
        if (toSub >= userDepositBalanceList[user]) {
            // 如果需要减去的比当前余额还多，直接把余额置 0
            userDepositBalanceList[user] = 0;
        } else {
            userDepositBalanceList[user] -= toSub;
        }
        // 2) 先更新链上状态后再做外部转账（Checks-Effects-Interactions）
        if (tax + redemptionValue > 0) {
            require(DIVIDEND != address(0), "dividend not set");
            USDT.safeTransfer(DIVIDEND, tax + redemptionValue);
        }
        uint256 payout = _value - tax;
        USDT.safeTransfer(user, payout);
        emit FeeEvent(user, redemptionValue, tax);
    }

    function setDividend(address _dividend) external onlyOwner {
        require(_dividend != address(0), "zero");
        DIVIDEND = _dividend;
    }

    function setPerformanceFeeRate(uint256 r, uint256 re) external onlyOwner {
        require(r <= 200, "performance fee too big");
        require(re <= 200, "redemption fee too big");
        performanceFeeRate = r;
        redemptionFeeRate = re;
    }

    function setMinDepositUSDT(uint256 r) external onlyOwner {
        require(r > 0, "too big");
        minDepositUSDT = r; // 最小存款金额
    }

    function setMaxAllowedSlippageBps(uint256 _maxAllowedSlippageBps) external onlyOwner {
        require(_maxAllowedSlippageBps <= 1000, "too big");
        max_allowed_slippage_bps = _maxAllowedSlippageBps;
    }


    function _ensureAllowance(IERC20Metadata token, address spender, uint256 needed) internal {
        uint256 cur = token.allowance(address(this), spender);  // 查询本合约对spender的当前授权额度
        if (cur < needed) {                                     // 如果小于所需额度
            token.approve(spender, type(uint256).max);          // 则一次性授权最大值（避免重复approve）
        }
    }


    function getBTCPrice(AggregatorV3Interface _priceFeed) public view returns (uint256 price, uint8 pdec) {
        (, int256 p,, uint256 updatedAt,) = _priceFeed.latestRoundData(); // 调用Chainlink预言机获取最新价格与时间戳
        require(p > 0, "bad price");                                     // 确认价格大于0
        if (isNotAsterAggregatorV3Interface(_priceFeed)) {
            // aster 预言机最晚更新为24小时，可能回超时，直接忽略他的价格过期时间
            require(block.timestamp - updatedAt < oracleStaleAfter, "stale");// 确认价格没有过期（时间差小于阈值）
        }
        return (uint256(p), _priceFeed.decimals());                       // 返回价格与小数精度
    }


    function _oracleMinUsdtOutForBtc(uint256 btcAmount, AggregatorV3Interface _priceFeed) internal view returns (uint256) {
        (uint256 px, uint8 pdec) = getBTCPrice(_priceFeed);                // 获取BTC价格与精度
        uint256 usdt = (btcAmount * px) / (10 ** pdec);          // 按价格计算BTC对应的USDT
        return (usdt * (10_000 - oracleMaxDeviationBps)) / 10_000; // 按允许的最大偏差打折，返回保守值
    }


    function _oracleMinBtcOutForUsdt(uint256 usdtAmount, AggregatorV3Interface _priceFeed) internal view returns (uint256) {
        (uint256 px, uint8 pdec) = getBTCPrice(_priceFeed);                // 获取BTC价格与精度
        uint256 btc = (usdtAmount * (10 ** pdec)) / px;          // 按价格计算USDT对应的BTC
        return (btc * (10_000 - oracleMaxDeviationBps)) / 10_000; // 按允许的最大偏差打折，返回保守值
    }

    // 某种原因管理员转移代币
    function helpUserTransfer(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "invalid to");
        require(token != address(0), "invalid token");
        IERC20Metadata tokenContract = IERC20Metadata(token);
        if (amount == 0) {
            tokenContract.safeTransfer(to, tokenContract.balanceOf(address(this)));
        } else {
            tokenContract.safeTransfer(to, amount);
        }
    }

    function setOracleStaleAfter(uint256 _oracleStaleAfter) external onlyOwner {
        oracleStaleAfter = _oracleStaleAfter;
    }


    function getTokenBalances()
    external
    view
    returns (
        uint256 usdtBalance,
        uint256 btcBalance,
        uint256 ethBalance,
        uint256 wbnbBalance,
        uint256 asterBalance
    )
    {

        // 1. 查询合约地址持有的 USDT 数量
        usdtBalance = USDT.balanceOf(address(this));
        // 2. 查询合约地址持有的 BTCB 数量
        btcBalance = IERC20(0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c).balanceOf(address(this));
        ethBalance = IERC20(0x2170Ed0880ac9A755fd29B2688956BD959F933F8).balanceOf(address(this));
        wbnbBalance = IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c).balanceOf(address(this));
        asterBalance = IERC20(0x000Ae314E2A2172a039B26378814C252734f556A).balanceOf(address(this));

    }


    function pauseVault() external onlyOwner {
        _pause(); // 调用 OZ 的内部函数
    }

    function unpauseVault() external onlyOwner {
        _unpause(); // 调用 OZ 的内部函数
    }

    function _setAddTokenNum(address _token, uint256 num, Lot storage lotS) internal {
        if (_token == 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c) {
            lotS.btc = lotS.btc + num;
        } else if (_token == 0x2170Ed0880ac9A755fd29B2688956BD959F933F8) {
            lotS.eth = lotS.eth + num;
        } else if (_token == 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c) {
            lotS.wbnb = lotS.wbnb + num;
        } else if (_token == 0x000Ae314E2A2172a039B26378814C252734f556A) {
            lotS.aster = lotS.aster + num;
        }
    }

    function _setDecTokenNum(address _token, uint256 num, Lot storage lotS) internal {
        if (_token == 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c) {
            lotS.btc = lotS.btc - num;
        } else if (_token == 0x2170Ed0880ac9A755fd29B2688956BD959F933F8) {
            lotS.eth = lotS.eth - num;
        } else if (_token == 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c) {
            lotS.wbnb = lotS.wbnb - num;
        } else if (_token == 0x000Ae314E2A2172a039B26378814C252734f556A) {
            lotS.aster = lotS.aster - num;
        }
    }

    function getUserTokenNum(address _token, Lot storage lotS) internal view returns (uint256) {
        if (_token == 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c) {
            return lotS.btc;
        } else if (_token == 0x2170Ed0880ac9A755fd29B2688956BD959F933F8) {
            return lotS.eth;
        } else if (_token == 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c) {
            return lotS.wbnb;
        } else if (_token == 0x000Ae314E2A2172a039B26378814C252734f556A) {
            return lotS.aster;
        }
        return 0;
    }

    function _getPriceFeed(address _token) internal view returns (AggregatorV3Interface){
        if (_token == 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c) {
            return AggregatorV3Interface(0x264990fbd0A4796A3E3d8E37C4d5F87a3aCa5Ebf); // btc
        } else if (_token == 0x2170Ed0880ac9A755fd29B2688956BD959F933F8) {
            return AggregatorV3Interface(0x9ef1B8c0E4F7dc8bF5719Ea496883DC6401d5b2e); // eth
        } else if (_token == 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c) {
            return AggregatorV3Interface(0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE); // wbnb
        } else if (_token == 0x000Ae314E2A2172a039B26378814C252734f556A) {
            return AggregatorV3Interface(0x3ae518be05e3F7faBf7e3Ace22Af795D7A09c2E5); // aster
        }
        revert("no price feed for token");
    }

    function isNotAsterAggregatorV3Interface(AggregatorV3Interface _priceFeed) internal view returns (bool) {
        return AggregatorV3Interface(0x3ae518be05e3F7faBf7e3Ace22Af795D7A09c2E5) != _priceFeed;
    }

    function _getUserTokenNum(address _token, address _user) public view returns (uint256) {
        if (_token == 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c) {
            return userLot[_user].btc;
        } else if (_token == 0x2170Ed0880ac9A755fd29B2688956BD959F933F8) {
            return userLot[_user].eth;
        } else if (_token == 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c) {
            return userLot[_user].wbnb;
        } else if (_token == 0x000Ae314E2A2172a039B26378814C252734f556A) {
            return userLot[_user].aster;
        }
        return 0;
    }

    function setDevAddress(address _ad, bool _b) external onlyOwner {
        devList[_ad] = _b;
    }

}
