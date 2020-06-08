pragma solidity ^0.4.26;
import "./TransactionFee.sol";
import "./CompoundOracleInterface.sol";
import "./SafeMath.sol";
import "./IERC20.sol";
import "./IOptionsManager.sol";
contract MatchMakingTrading is TransactionFee {
    using SafeMath for uint256;
    //sell options order defination
    struct SellOptionsOrder {
        address owner;
        uint256 createdTime;
        uint256 amount;
    }
    //pay options order defination
    struct PayOptionsOrder {
        address owner;
        uint256 createdTime;
        uint256 amount;
        uint256 settlementsAmount;
    }
    //_tradingEnd is a deadline of a options token trading. All orders can trade before optionsToken's expiration-tradingEnd. After that time,
    //all Orders will be retrurned back to the owner.
    uint256 private _tradingEnd = 5 hours;
    //options manager interface;
    IOptionsManager private _optionsManager;
    //oracle interface.
    ICompoundOracle private _oracle;
    //mapping settlementCurrency => OptionsToken => OptionsOrder
    mapping(address => mapping(address => PayOptionsOrder[])) public payOrderMap;
    mapping(address => mapping(address => SellOptionsOrder[])) public sellOrderMap;

    event AddPayOrder(address indexed from,address indexed optionsToken,address indexed settlementCurrency,uint256 amount, uint256 settlementsAmount);
    event AddSellOrder(address indexed from,address indexed optionsToken,address indexed settlementCurrency,uint256 amount);
    event SellOptionsToken(address indexed from,address indexed optionsToken,address indexed settlementCurrency,uint256 optionsPrice,uint256 amount);
    event BuyOptionsToken(address indexed from,address indexed optionsToken,address indexed settlementCurrency,uint256 optionsPrice,uint256 amount);
    event ReturnExpiredOrders(address indexed optionsToken);
    event RedeemPayOrder(address indexed from,address indexed optionsToken,address indexed settlementCurrency,uint256 amount);
    event RedeemSellOrder(address indexed from,address indexed optionsToken,address indexed settlementCurrency,uint256 amount);
    event DebugEvent(uint256 value0,uint256 value1,uint256 value2);
    //*******************getter***********************
    function getOracleAddress() public view returns(address){
        return address(_oracle);
    }
    function getOptionsManagerAddress() public view returns(address){
        return address(_optionsManager);
    }
    function getTradingEnd() public view returns(uint256){
        return _tradingEnd;
    }
    /**
      * @dev getting all of the pay orders;
      * @param optionsToken options token address
      * @param settlementCurrency the settlement currency address
      * @return owner account, created time, buy amount, settlements deposition.
      */
    function getPayOrderList(address optionsToken,address settlementCurrency) public view returns(address[],uint256[],uint256[],uint256[]){
        PayOptionsOrder[] storage payOrders = payOrderMap[settlementCurrency][optionsToken];
        address[] memory owners = new address[](payOrders.length);
        uint256[] memory times = new uint256[](payOrders.length);
        uint256[] memory amounts = new uint256[](payOrders.length);
        uint256[] memory settlements = new uint256[](payOrders.length);
        for (uint i=0;i<payOrders.length;i++){
            owners[i] = payOrders[i].owner;
            times[i] = payOrders[i].createdTime;
            amounts[i] = payOrders[i].amount;
            settlements[i] = payOrders[i].settlementsAmount;
        }
        return (owners,times,amounts,settlements);
    }
    /**
      * @dev getting all of the sell orders;
      * @param optionsToken options token address
      * @param settlementCurrency the settlement currency address
      * @return owner account, created time, sell amount.
      */
    function getSellOrderList(address optionsToken,address settlementCurrency) public view returns(address[],uint256[],uint256[]){
         SellOptionsOrder[] storage sellOrders = sellOrderMap[settlementCurrency][optionsToken];
        address[] memory owners = new address[](sellOrders.length);
        uint256[] memory times = new uint256[](sellOrders.length);
        uint256[] memory amounts = new uint256[](sellOrders.length);
        for (uint i=0;i<sellOrders.length;i++){
            owners[i] = sellOrders[i].owner;
            times[i] = sellOrders[i].createdTime;
            amounts[i] = sellOrders[i].amount;
        }
        return (owners,times,amounts);
    }
    //*******************setter***********************
    function setOracleAddress(address oracle)public onlyOwner{
        _oracle = ICompoundOracle(oracle);
    }
    function setOptionsManagerAddress(address optionsManager)public onlyOwner{
        _optionsManager = IOptionsManager(optionsManager);
    }
    function setTradingEnd(uint256 tradingEnd) public onlyOwner {
        _tradingEnd = tradingEnd;
    }
    /**
      * @dev add a pay order, if your deposition is insufficient, your order will be disable.
      * @param optionsToken options token address
      * @param settlementCurrency the settlement currency address
      * @param deposit you need to deposit some settlement currency to pay the order.deposit is the amount of settlement currency to pay.
      * @param buyAmount the options token amount you want to buy.
      */
    function addPayOrder(address optionsToken,address settlementCurrency,uint256 deposit,uint256 buyAmount) public payable{
        require(isEligibleAddress(settlementCurrency),"This settlements currency is ineligible");
        require(isEligibleOptionsToken(optionsToken),"This options token is ineligible");
        uint256 tokenPrice = _oracle.getSellOptionsPrice(optionsToken);
        uint256 currencyPrice = _oracle.getPrice(settlementCurrency);
        uint256 optionsPay;
        uint256 transFee;
        (optionsPay,transFee) = _calPayment(buyAmount,tokenPrice,currencyPrice);
        uint256 settlements = deposit;
        if (settlementCurrency == address(0)){
            settlements = msg.value;
        }else{
            IERC20 settlement = IERC20(settlementCurrency);
            settlement.transferFrom(msg.sender,address(this),settlements);           
        }
        require(optionsPay.add(transFee)<=settlements,"settlements Currency is insufficient!");
        payOrderMap[settlementCurrency][optionsToken].push(PayOptionsOrder(msg.sender,now,buyAmount,settlements));
        emit AddPayOrder(msg.sender,optionsToken,settlementCurrency,buyAmount,settlements);
    }
    /**
      * @dev add a sell order. The Amount of options token will be transfered into contract address.
      * @param optionsToken options token address
      * @param settlementCurrency the settlement currency address
      * @param amount the options token amount you want to sell.
      */
    function addSellOrder(address optionsToken,address settlementCurrency,uint256 amount) public {
        require(isEligibleAddress(settlementCurrency),"This settlements currency is ineligible");
        require(isEligibleOptionsToken(optionsToken),"This options token is ineligible");
        IERC20 ERC20Token = IERC20(optionsToken);
        ERC20Token.transferFrom(msg.sender,address(this),amount);  
        sellOrderMap[settlementCurrency][optionsToken].push(SellOptionsOrder(msg.sender,now,amount));
        emit AddSellOrder(msg.sender,optionsToken,settlementCurrency,amount);
    }
    /**
      * @dev redeem a pay order.redeem the earliest pay order.return back the deposition.
      * @param optionsToken options token address
      * @param settlementCurrency the settlement currency address
      */    
    function redeemPayOrder(address optionsToken,address settlementCurrency) public{
        require(isEligibleAddress(settlementCurrency),"This settlements currency is ineligible");
        require(isEligibleOptionsToken(optionsToken),"This options token is ineligible");
        PayOptionsOrder[] storage orderList = payOrderMap[settlementCurrency][optionsToken];
        for (uint256 i=0;i<orderList.length;i++){
            if (orderList[i].owner == msg.sender){
                uint256 payAmount = orderList[i].settlementsAmount;
                if (orderList[i].settlementsAmount > 0){
                    orderList[i].settlementsAmount = 0;
                    if (settlementCurrency == address(0)) {
                        orderList[i].owner.transfer(payAmount);                
                    }else {
                        IERC20 settlement = IERC20(settlementCurrency);
                        settlement.transfer(orderList[i].owner,payAmount);           
                    }
                }
                emit RedeemPayOrder(msg.sender,optionsToken,settlementCurrency,orderList[i].amount);
                for (uint256 j=i+1;j<orderList.length;j++) {
                    orderList[i].owner = orderList[j].owner;
                    orderList[i].createdTime = orderList[j].createdTime;
                    orderList[i].amount = orderList[j].amount;
                    orderList[i].settlementsAmount = orderList[j].settlementsAmount;
                    i++;
                }
                orderList.length--;
                break;
            }
        }

    }
    /**
      * @dev redeem a sell order.redeem the earliest sell order.return back the options token.
      * @param optionsToken options token address
      * @param settlementCurrency the settlement currency address
      */    
    function redeemSellOrder(address optionsToken,address settlementCurrency) public {
        require(isEligibleAddress(settlementCurrency),"This settlements currency is ineligible");
        require(isEligibleOptionsToken(optionsToken),"This options token is ineligible");
        SellOptionsOrder[] storage orderList = sellOrderMap[settlementCurrency][optionsToken];
        for (uint256 i=0;i<orderList.length;i++){
            if (orderList[i].owner == msg.sender){
                uint256 tokenAmount = orderList[i].amount;
                if (orderList[i].amount > 0){
                    orderList[i].amount = 0;
                    IERC20 options = IERC20(optionsToken);
                    options.transfer(orderList[i].owner,tokenAmount);
                }
                emit RedeemSellOrder(msg.sender,optionsToken,settlementCurrency,tokenAmount);
                for (uint256 j=i+1;j<orderList.length;j++) {
                    orderList[i].owner = orderList[j].owner;
                    orderList[i].createdTime = orderList[j].createdTime;
                    orderList[i].amount = orderList[j].amount;
                    i++;
                }
                orderList.length--;
                break;
            }
        }
    }
    /**
      * @dev buy amount options token form sell order.
      * @param optionsToken options token address
      * @param amount options token amount you want to buy
      * @param settlementCurrency the settlement currency address
      * @param currencyAmount the settlement currency amount will be payed for
      */     
    function buyOptionsToken(address optionsToken,uint256 amount,address settlementCurrency,uint256 currencyAmount) public payable {
        uint256 tokenPrice = _oracle.getBuyOptionsPrice(optionsToken);
        uint256 currencyPrice = _oracle.getPrice(settlementCurrency);
        if (settlementCurrency == address (0)) {
            currencyAmount = msg.value;
        }
        uint256 allPay = 0;
        uint256 transFee = 0;
        (allPay,transFee) = _calPayment(amount,tokenPrice,currencyPrice);
        require(allPay.add(transFee)<=currencyAmount,"pay value is insufficient!");
        uint256 _totalBuy = 0;
        SellOptionsOrder[] storage orderList = sellOrderMap[settlementCurrency][optionsToken];
        for (uint256 i=0;i<orderList.length;i++) {
            uint256 optionsAmount = amount;
            if (amount > orderList[i].amount) {
                optionsAmount = orderList[i].amount;
            }
            amount = amount.sub(optionsAmount);
            _totalBuy = _totalBuy.add(optionsAmount);
            uint256 sellAmount = 0;
            (sellAmount,currencyAmount) = _orderTrading(optionsToken,optionsAmount,tokenPrice,settlementCurrency,currencyAmount,currencyPrice,
            orderList[i].owner,msg.sender);
            orderList[i].amount = orderList[i].amount.sub(sellAmount);
            if (amount == 0) {
                break;
            }
        }
        if (currencyAmount > 0) {
            if (settlementCurrency == address(0)) {
                msg.sender.transfer(currencyAmount);                
            }else {
                IERC20 settlement = IERC20(settlementCurrency);
                settlement.transfer(msg.sender,currencyAmount);           
            }           
        }
        emit BuyOptionsToken(msg.sender,optionsToken,settlementCurrency,tokenPrice,_totalBuy);
        _removeEmptySellOrder(optionsToken,settlementCurrency);
    }
    /**
      * @dev sell amount options token to buy order.
      * @param optionsToken options token address
      * @param amount options token amount you want to sell
      * @param settlementCurrency the settlement currency address
      */      
    function sellOptionsToken(address optionsToken,uint256 amount,address settlementCurrency) public {
        uint256 tokenPrice = _oracle.getSellOptionsPrice(optionsToken);
        uint256 currencyPrice = _oracle.getPrice(settlementCurrency);
        uint256 _totalSell = 0;
        IERC20 erc20Token = IERC20(optionsToken);
        erc20Token.transferFrom(msg.sender,address(this),amount);
        PayOptionsOrder[] storage orderList = payOrderMap[settlementCurrency][optionsToken];
        for (uint256 i=0;i<orderList.length;i++){
            if (!_isSufficientSettlements(orderList[i],tokenPrice,currencyPrice)){
                continue;
            }
            uint256 optionsAmount = amount;
            if (optionsAmount > orderList[i].amount) {
                optionsAmount = orderList[i].amount;
            }

            amount = amount.sub(optionsAmount);            
            uint256 sellAmount = 0;
            uint256 leftCurrency = 0;
            (sellAmount,leftCurrency) = _orderTrading(optionsToken,optionsAmount,tokenPrice,settlementCurrency,orderList[i].settlementsAmount,currencyPrice,
            msg.sender,orderList[i].owner);
            _totalSell = _totalSell.add(sellAmount);
            emit DebugEvent(2,amount,_totalSell);
            emit DebugEvent(3,sellAmount,leftCurrency);
            orderList[i].amount = orderList[i].amount.sub(sellAmount);
            orderList[i].settlementsAmount = leftCurrency;
            if (amount == 0) {
                break;
            }
        }
        if (amount > 0){
            erc20Token.transfer(msg.sender,amount);
        }
        emit SellOptionsToken(msg.sender,optionsToken,settlementCurrency,tokenPrice,_totalSell);
        _removeEmptyPayOrder(optionsToken,settlementCurrency);
    }
    /**
      * @dev return back the expired options token orders. Both buy orders and sell orders
      */        
    function returnExpiredOrders()public{
        address[] memory options = _optionsManager.getOptionsTokenList();
        for (uint256 i=0;i<options.length;i++){
            if (!isEligibleOptionsToken(options[i])){
                for (uint j=0;j<whiteList.length;j++){
                    _returnExpiredSellOrders(options[i],whiteList[j]);
                    _returnExpiredPayOrders(options[i],whiteList[j]);
                }
                emit ReturnExpiredOrders(options[i]);
            }
        }
    }
    function _orderTrading(address optionsToken,uint256 amount,uint256 optionsPrice,
            address settlementCurrency,uint256 currencyAmount,uint256 currencyPrice,
            address seller,address buyer) internal returns (uint256,uint256) {
        uint256 optionsPay = 0;
        uint256 transFee = 0;
        (optionsPay,transFee) = _calPayment(amount,optionsPrice,currencyPrice);
        if (optionsPay.add(transFee)>currencyAmount){
            return (0,currencyAmount);
        }
        IERC20 erc20Token = IERC20(optionsToken);
        erc20Token.transfer(buyer,amount);
        if (settlementCurrency == address(0)){
            seller.transfer(optionsPay);
            
        }else{
            IERC20 settlement = IERC20(settlementCurrency);
            settlement.transfer(seller,optionsPay);           
        }
        optionsPay = optionsPay.add(transFee);
        currencyAmount = currencyAmount.sub(optionsPay);
        _addTransactionFee(settlementCurrency,transFee);
        return (amount,currencyAmount);
    }
    function _removeEmptyPayOrder(address optionsToken,address settlementCurrency)internal{
        PayOptionsOrder[] storage orderList = payOrderMap[settlementCurrency][optionsToken];
        uint256 index = 0;
        for (uint i=0;i<orderList.length;i++) {
            if (orderList[i].amount > 0) {
                if(i != index) {
                    orderList[index].owner = orderList[i].owner;
                    orderList[index].createdTime = orderList[i].createdTime;
                    orderList[index].amount = orderList[i].amount;
                    orderList[index].settlementsAmount = orderList[i].settlementsAmount;
                }
                index++;
            }else {
                if (orderList[i].settlementsAmount > 0) {
                    uint256 payAmount = orderList[i].settlementsAmount;
                    orderList[i].settlementsAmount = 0;
                    if (settlementCurrency == address(0)) {
                        emit DebugEvent(123,i,payAmount);
                    }else {
                        IERC20 settlement = IERC20(settlementCurrency);
                        settlement.transfer(orderList[i].owner,payAmount);           
                    }           

                }
            }
        }
         if (index < orderList.length) {
            orderList.length = index;
        }

    }
    function _removeEmptySellOrder(address optionsToken,address settlementCurrency)internal{
        SellOptionsOrder[] storage orderList = sellOrderMap[settlementCurrency][optionsToken];
        uint256 index = 0;
        for (uint i=0;i<orderList.length;i++) {
            if (orderList[i].amount > 0) {
                if(i != index) {
                    orderList[index].owner = orderList[i].owner;
                    orderList[index].createdTime = orderList[i].createdTime;
                    orderList[index].amount = orderList[i].amount;
                }
                index++;
            }
        }
        if (index < orderList.length) {
            orderList.length = index;
        }
    }
    function _isSufficientSettlements(PayOptionsOrder storage payOrder,uint256 optionsPrice,uint256 currencyPrice) internal view returns(bool){
        uint256 allPay = 0;
        uint256 transFee = 0;
        (allPay,transFee) = _calPayment(payOrder.amount,optionsPrice,currencyPrice);
        if (allPay.add(transFee) > payOrder.settlementsAmount){
            return false;
        }
        return true;
    }
    function _calPayment(uint256 amount,uint256 optionsPrice,uint256 currencyPrice) internal view returns (uint256,uint256) {
        uint256 allPayment = optionsPrice.mul(amount);
        uint256 optionsPay = allPayment.div(currencyPrice);
        uint256 transFee = _calNumberMulUint(transactionFee,optionsPay);
        optionsPay = optionsPay.sub(transFee);
        transFee = transFee.mul(2);
        return (optionsPay,transFee);
    }
    function _returnExpiredSellOrders(address optionsToken,address settlementCurrency) internal {
        IERC20 options = IERC20(optionsToken);
        SellOptionsOrder[] storage orderList = sellOrderMap[settlementCurrency][optionsToken];
        for (uint i=0;i<orderList.length;i++) {
            if (orderList[i].amount > 0) {
                uint256 tokenAmount = orderList[i].amount;
                orderList[i].amount = 0;
                options.transfer(orderList[i].owner,tokenAmount);
            }
        }
        delete sellOrderMap[settlementCurrency][optionsToken];
    }
    function _returnExpiredPayOrders(address optionsToken,address settlementCurrency) internal{
        PayOptionsOrder[] storage orderList = payOrderMap[settlementCurrency][optionsToken];
        for (uint i=0;i<orderList.length;i++) {
            if (orderList[i].settlementsAmount > 0) {
                uint256 payAmount = orderList[i].settlementsAmount;
                orderList[i].settlementsAmount = 0;
                if (settlementCurrency == address(0)) {
                    orderList[i].owner.transfer(payAmount);                
                }else {
                    IERC20 settlement = IERC20(settlementCurrency);
                    settlement.transfer(orderList[i].owner,payAmount);           
                }   
             }
        }
        delete payOrderMap[settlementCurrency][optionsToken];
    }
    function isEligibleOptionsToken(address optionsToken) public view returns(bool) {
        uint256 expiration;
        bool exercised;
        (,,,,expiration,exercised) = _optionsManager.getOptionsTokenInfo(optionsToken);
        uint256 tradingEnd = _tradingEnd.add(now);
        return (expiration > 0 && tradingEnd < expiration && !exercised);
    }
}