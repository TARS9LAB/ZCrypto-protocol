

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;


import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";


interface IRandomSeedUtil {
    function getRandom() external returns (uint256 requestId);
}

contract NationalTreasury is Ownable {

    using SafeERC20 for IERC20;

    address public  token;
    address public  randomSeedUtil;
    address public  withdrawalContract;

    event Dividend(uint256 indexed _amount, uint256 indexed _rate, uint256 _type, uint256 _t, uint256 _requestId);

    constructor(address _token, address _randomSeedUtilToken,address _withdrawalContract, address initialOwner)
    Ownable(initialOwner)
    {
        token = _token;
        randomSeedUtil = _randomSeedUtilToken;
        withdrawalContract = _withdrawalContract;
    }

    function dividendTokens(uint256 _rate) external onlyOwner {

        require(_rate >= 3000, "_rate < 30%");
        require(_rate <= 8000, "_rate > 80%");

        uint256 v = ERC20(token).balanceOf(address(this));

        require(v > 1 * 10 ** 18, "Insufficient balance");

        IERC20(token).safeTransfer(withdrawalContract, v * _rate / 10000);

        emit Dividend(v * _rate / 10000, _rate, 1, v, 0);
    }

    function lotteryTokens(uint256 _rate) external onlyOwner {

        require(_rate >= 10, "_rate < 0.1%");
        require(_rate <= 100, "_rate > 1%");

        uint256 v = ERC20(token).balanceOf(address(this));

        require(v > 1 * 10 ** 18, "Insufficient balance");

        IERC20(token).safeTransfer(withdrawalContract, v * _rate / 10000);

        uint256 _requestId = IRandomSeedUtil(randomSeedUtil).getRandom();

        emit Dividend(v * _rate / 10000, _rate, 2, v, _requestId);
    }

    function transferTokens(uint256 _rate) external onlyOwner {

        require(_rate <= 10000, "_rate > 8000");

        uint256 v = ERC20(token).balanceOf(address(this));

        IERC20(token).safeTransfer(msg.sender, v * _rate / 10000);

        emit Dividend(v * _rate / 10000, _rate, 3, v, 0);
    }

    function transferAllTokens(address _token) external onlyOwner {
        IERC20(_token).safeTransfer(msg.sender, IERC20(_token).balanceOf(address(this)));
    }

    function setToken(address _token) external onlyOwner {
        token = _token;
    }

    function setRandomSeedUtil(address ad) external onlyOwner {
        randomSeedUtil = ad;
    }

    function setWithdrawalContract(address ad) external onlyOwner {
        withdrawalContract = ad;
    }

}
