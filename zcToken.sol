

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;


import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";


interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

contract ZcToken is ERC20, ERC20Burnable, Ownable, ERC20Permit {
    address public immutable usdt = 0x55d398326f99059fF775485246999027B3197955;
    mapping(address => bool) public _excludedFees;
    mapping(address => bool) public _blackList;
    mapping(address => bool) public routers;

    IUniswapV2Router02 public uniswapRouter;
    address public uniswapPair;

    address public feeAddress = 0xa38aE68C03c1BA6e32B3AE4Ec26f58Fb2C6030AB; // 国库地址，用来分红抽奖


    uint256 public buyRate = 0; // 买手续费
    uint256 public sellRate = 0; // 卖手续费

    bool public isBuyFee = true; // false off ,true on
    bool public isSellFee = true; // false off ,true on

    event FeeEvent(address indexed _from, address indexed _to, uint256 indexed _v);
    event TransferEvent(address indexed _user, address indexed _to, uint256 _v);


    uint256 public minTime = 10; // 交易冷却使时间，防止机器人
    mapping(address => uint256) public lastBuyTimestamp;

    constructor(address initialOwner)
    ERC20("ZC", "ZC")
    Ownable(initialOwner)
    ERC20Permit("ZC")
    {
        uniswapRouter = IUniswapV2Router02(
            0x10ED43C718714eb63d5aA57B78B54704E256024E //pancake
        //0xD99D1c33F9fC3444f8101754aBC46c52416550D1 //testnet pancake
        );
        uniswapPair = IUniswapV2Factory(uniswapRouter.factory()).createPair(
            address(this),
            usdt
        );
        _excludedFees[address(this)] = true;
        _excludedFees[feeAddress] = true;
        _excludedFees[initialOwner] = true;

        _mint(initialOwner, 400_000_000 * 10 ** 18); // 总计4亿代币
    }

    function _update(address from, address to, uint256 value) internal virtual override {
        require(!_blackList[from] && !_blackList[to], "BL");

        bool isBuy = uniswapPair == from;
        bool isSell = uniswapPair == to;
        bool shouldTakeFee = !_excludedFees[from] && !_excludedFees[to];
        uint256 feeAmount = 0;

        if (isBuy) {
            lastBuyTimestamp[to] = block.timestamp;
        }

        if (isSell) {
            // 10秒冷却限制
            if (shouldTakeFee) {
                require(
                    block.timestamp >= lastBuyTimestamp[from] + minTime,
                    "Sell too soon: please wait 10 seconds after buying"
                );
            }
        }

        if (isBuy && shouldTakeFee && isBuyFee) {
            // 买入逻辑 买手续费
            feeAmount = value * buyRate / 1000;
            if (feeAmount > 0) {
                super._update(from, feeAddress, feeAmount);
                value = value - feeAmount;
                emit FeeEvent(from, to, feeAmount);
            }
            super._update(from, to, value);
            return; // 买入分支结束
        }

        if (isSell && shouldTakeFee && isSellFee) {
            uint256 sellAmount = value;
            feeAmount = (sellAmount * sellRate) / 1000;
            uint256 transferAmount = sellAmount - feeAmount;
            // 防清仓：如果用户卖光，就强制留 0.000001
            if (sellAmount == balanceOf(from)) {
                require(transferAmount > 10 ** 12, "Amount too small");
                transferAmount -= 10 ** 12;
            }
            if (feeAmount > 0) {
                super._update(from, feeAddress, feeAmount);
                emit FeeEvent(from, to, feeAmount);
            }
            super._update(from, to, transferAmount);
            return; // 卖出分支结束
        }

        if (!isBuy && !isSell) {
            // 防清仓：如果用户转光，就强制留 0.000001
            if (value == balanceOf(from)) {
                require(value > 10 ** 12, "Amount too small");
                value -= 10 ** 12;
            }
            emit TransferEvent(from, to, value);
            if (lastBuyTimestamp[from] > lastBuyTimestamp[to]) {
                lastBuyTimestamp[to] = lastBuyTimestamp[from];
            }
        }
        super._update(from, to, value);
    }

    function setFee(uint256 _buyRate, uint256 _sellRate) external onlyOwner {

        require(_buyRate <= 1000 && _sellRate <= 1000, "fee too high");
        buyRate = _buyRate;
        sellRate = _sellRate;
    }

    function setIsFee(bool _isBuyFee, bool _isSellFee) external onlyOwner {
        isBuyFee = _isBuyFee;
        isSellFee = _isSellFee;
    }

    function setBlackList(address user, bool b) external onlyOwner {
        _blackList[user] = b;
    }

    function setExcludedFees(address user, bool b) external onlyOwner {
        _excludedFees[user] = b;
    }

    function setExcludedFeesBatch(address[] memory users, bool b) external onlyOwner {
        for (uint256 index = 0; index < users.length; index++) {
            _excludedFees[users[index]] = b;
        }
    }

    function setMinTime(uint256 value) external onlyOwner {
        minTime = value;
    }

    function getTokenPrice() public view returns (uint256 price) {

        IUniswapV2Pair pair = IUniswapV2Pair(uniswapPair);

        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();

        address token0 = pair.token0();

        require(reserve0 > 0 && reserve1 > 0, "No liquidity");

        if (address(this) == token0) {
            price = (uint256(reserve1) * 1e18) / uint256(reserve0);
        } else {
            price = (uint256(reserve0) * 1e18) / uint256(reserve1);
        }
    }
}
