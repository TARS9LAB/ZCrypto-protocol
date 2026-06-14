
### 环境：
```
Nginx+ PHP8.2 + Mysql5.7
```
### 运行目录：
```
/public
```

### 后台管理：https://域名/adminPKJHlihawf
```
用户名：admin  
密码：admin888
```

### 添加laravel伪静态
```bash
location / {
    try_files $uri $uri/ /index.php?$query_string;
}
```
### 关闭开发模式

php artisan cache
php artisan config:clear
php artisan route:cache
php artisan optimize:clear
/www/server/php/83/bin/php

### 先启动 这个是启动wokerman
php start.php start
### 这是启动币安k线图
php artisan binance:workerman start
```
### 清空数据表
```
### 币安key线图
TRUNCATE `binance_klines`;
### 基金取款记录
TRUNCATE `web_withdraw_btc`;
### 存款记录
TRUNCATE `web_fancy_btc`;
### link 随机数种子
TRUNCATE `web_number_seed`;
### zc 代币买卖记录
TRUNCATE `web_buy_sell`;
### 用户资产明细表
TRUNCATE `user_assets_detail`;
### 用户浮盈浮亏记录表
TRUNCATE `web_user_float_detail`;
### 用户浮盈浮亏记录表
TRUNCATE `web_user_float_rank`;
### 用户分红 抽奖 记录
TRUNCATE `web_treasury_dividends`;
### zc 代币价格记录表
TRUNCATE `web_token_price`;
### btc 代币价格记录表 5分钟
TRUNCATE `web_btc_price`;
### 用户提现记录表
TRUNCATE `user_withdrawal`;
### 用户充值记录表
TRUNCATE `recharge_detail`;
### 错误日志
TRUNCATE `user_error`;
### 质押订单
TRUNCATE `user_pledge_order`;
### 质押释放明细
TRUNCATE `user_pledge_release`;
### 限价订单
TRUNCATE `web_limit_entry_detail`;
### 预测表
TRUNCATE `web_predict_btc_price`;
### 预测输赢表
TRUNCATE `web_predict_detail`;
### 抽奖明细
TRUNCATE `web_lottery_detail`;
### 代币买卖转账记录表
TRUNCATE `web_btc_buy_sell`;



delete from `user_assets` where id > 1;
delete from `users` where id > 1;

update `users` set direct_referral=0 where id > 0;
update `users` set level=0 where id > 0;
update `users` set token_num=0 where id > 0;

update `web_mining_config` set accumulate_mining_total=0,now_mining_rate=1,now_mining_phase=1,max_phase=10 where id = 1;

重要！！！ 重要！！！ 重要！！！

关闭开发者模式

UPDATE admin_users set username="修改管理员名称" where id = 1;
### 重置用户的邀请码
UPDATE `users` set uid='' where address = "0xf1eC33cC0dCD632e540d64CbFEe36779174D94a6";

```
###  定时任务
### 触发购买或者卖出zc事件 每30秒触发一次
cd /www/wwwroot/项目路径 && php artisan buyOrSellZcEvent

### ### 触发基金提现记录 每30秒触发一次
cd /www/wwwroot/项目路径 && php artisan withdrawEvent

### 每一小时计算浮亏或浮盈
cd /www/wwwroot/项目路径 && php artisan calcUserProfit

### 触发基金存款记录 每30秒触发一次
cd /www/wwwroot/项目路径 && php artisan depositCommitment

### 预测结算与开启新预测 每5分钟触发一次
cd /www/wwwroot/项目路径 && php artisan settlement_details

### 尝试限价挂单 每3秒执行一次
cd /www/wwwroot/项目路径 && php artisan limitPrice

### 触发种子数事件 每30秒钟执行一次
cd /www/wwwroot/项目路径 && php artisan numberSeedsEvent

### 质押释放和本金回退每天凌晨触发
cd /www/wwwroot/项目路径 && php artisan pledgeReleaseCmd

### 代币充值 每30秒执行一次
cd /www/wwwroot/项目路径 && php artisan rechargeToken

### 开始处理国库分红 每5分钟执行一次
cd /www/wwwroot/项目路径 && php artisan start_dividend_distribution

### 停止预测下注 每5分钟执行一次
cd /www/wwwroot/项目路径 && php artisan stop_predict_betting

### 同步区块链zc价格 每5分钟执行一次
cd /www/wwwroot/项目路径 && php artisan bsc:syncPrice

### 触发zc转账事件 每30秒执行一次
cd /www/wwwroot/项目路径 && php artisan transferZcEvent

### 提现验证 每5分钟执行一次
cd /www/wwwroot/项目路径 && php artisan withdrawalVerification



- 合约在线编译
https://remix.ethereum.org/#
- 合约错误在线追踪 
https://dashboard.tenderly.co/
- 付费节点
https://auth.quicknode.com/
- 免费节点
https://console.chainstack.com/user/account#login
- Chainlink
https://vrf.chain.link/bsc#/side-drawer/subscription/bsc/106003110247042070172338371663914054044761143209128250626214973401577855073437



