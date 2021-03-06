const functionModule = require ("./testFunctions");
var testCaseClass = require ("./testCases.js");
var checkBalance = require ("./checkBalance.js");
const BN = require("bn.js");
var OptionsManager = artifacts.require("OptionsManager");
var TestCompoundOracle = artifacts.require("TestCompoundOracle");
var FNXCoin = artifacts.require("FNXCoin");
var IERC20 = artifacts.require("IERC20");
let collateral0 = "0x0000000000000000000000000000000000000000";
let gasPrice = 20000000000;
var OptionsFormulas = artifacts.require("OptionsFormulas");
contract('OptionsManager', function (accounts){
    let test1 = new testCaseClass();
    it('OptionsManager adding Collateral case one', async function (){
        await test1.migrateOptionsManager();        
        let priceObj = {
            PriceList: [{
                address:collateral0,
                price:100000,
            }],
            underlyingAssets:[{
                id:1,
                price:100000,
            }]
        }
        let expiration = Math.floor(Date.now()/1000)+3600;
        let amount = 1000000000;
        test1.setOraclePrice(priceObj);
        console.log("call options adding collateral!");
        await testAddcollateral(collateral0,test1,expiration,0,amount,accounts);
        await testAddcollateralTwice(collateral0,test1,expiration,0,amount,accounts[2]);
        await testWithdrawCollateralAndBurnToken(collateral0,test1,expiration,0,amount,accounts[4]);
        console.log("put options adding collateral!");
        await testAddcollateral(collateral0,test1,expiration,1,amount,accounts);
        await testAddcollateralTwice(collateral0,test1,expiration,1,amount,accounts[3]);
        await testWithdrawCollateralAndBurnToken(collateral0,test1,expiration,1,amount,accounts[5]);
    });
    it('OptionsManager adding Token Collateral case one', async function (){
        await test1.migrateOptionsManager();  
        let fnxToken = await FNXCoin.deployed();     
        let mintAmount = new BN("10000000000000000000000000",10)
        for (var i=0;i<accounts.length;i++){
            await fnxToken.mint(accounts[i],mintAmount);
        }
        
        let priceObj = {
            PriceList: [{
                address:collateral0,
                price:100000,
            },{
                address:fnxToken.address,
                price:110000,
            }],
            underlyingAssets:[{
                id:1,
                price:100000,
            }]
        }
        let expiration = Math.floor(Date.now()/1000)+3600;
        let amount = 1000000000;
        test1.setOraclePrice(priceObj);
        console.log("call options adding collateral!");
        await testAddcollateral(fnxToken.address,test1,expiration,0,amount,accounts);
        await testAddcollateralTwice(fnxToken.address,test1,expiration,0,amount,accounts[2]);
        await testWithdrawCollateralAndBurnToken(fnxToken.address,test1,expiration,0,amount,accounts[4]);
        console.log("put options adding collateral!");
        await testAddcollateral(fnxToken.address,test1,expiration,1,amount,accounts);
        await testAddcollateralTwice(fnxToken.address,test1,expiration,1,amount,accounts[3]);
        await testWithdrawCollateralAndBurnToken(fnxToken.address,test1,expiration,1,amount,accounts[5]);
    });
    return
    it('OptionsManager adding Collateral case two', async function (){
        let priceObj = {
            PriceList: [{
                address:collateral0,
                price:10000,
            }],
            underlyingAssets:[{
                id:1,
                price:1000000,
            }]
        }
        let expiration = Math.floor(Date.now()/1000)+3600;
        let amount = 1000000000;
        test1.setOraclePrice(priceObj);
        console.log("call options adding collateral!");
        await testAddcollateral(collateral0,test1,expiration,0,amount,accounts);
        await testAddcollateralTwice(collateral0,test1,expiration,0,amount,accounts[2]);
        console.log("put options adding collateral!");
        await testAddcollateral(collateral0,test1,expiration,1,amount,accounts);
        await testAddcollateralTwice(collateral0,test1,expiration,1,amount,accounts[3]);
    });
    it('OptionsManager adding Collateral case three', async function (){
        let priceObj = {
            PriceList: [{
                address:collateral0,
                price:10000000,
            }],
            underlyingAssets:[{
                id:1,
                price:100000,
            }]
        }
        let expiration = Math.floor(Date.now()/1000)+3600;
        let amount = 1000000000;
        test1.setOraclePrice(priceObj);

        console.log("call options adding collateral!");
        await testAddcollateral(collateral0,test1,expiration,0,amount,accounts);
        await testAddcollateralTwice(collateral0,test1,expiration,0,amount,accounts[2]);
        console.log("put options adding collateral!");
        await testAddcollateral(collateral0,test1,expiration,1,amount,accounts);
        await testAddcollateralTwice(collateral0,test1,expiration,1,amount,accounts[3]);
    });
});
async function testAddcollateral(collateral,testCase,expiration,optType,amount,accounts){
    let underlyingAsset = 1;
    let strikePrices = await testCase.getTestStrikePriceList(underlyingAsset,optType);
    let checks = [new checkBalance("collateral",[],testCase.oracle)];
    if (collateral != collateral0){
        checks[0].token = await IERC20.at(collateral); 
    }
    for (var i=2;i<accounts.length;i++){
        checks[0].addAccount(accounts[i]);
    }
    checks[0].addAccount(testCase.manager.address);
   await checks[0].beforeFunction();
    for (var i = 0;i < strikePrices.length; i++) {
        let strikePrice = strikePrices[i];
        let token = await testCase.createOptionsToken(collateral,underlyingAsset,expiration,optType,strikePrice,checks[0]);
        let ercToken = await IERC20.at(token.address);
        let check1 = new checkBalance("token "+i,checks[0].accounts,testCase.oracle,ercToken);
        await check1.beforeFunction();
        checks.push(check1);
        let needMint = await testCase.calCollateralToMintAmount(token.address,amount,optType);
        let index = 1;
        for (var mintAmount = needMint+10;mintAmount>needMint-15;mintAmount-=10){
            let account = accounts[index];
            index++;
            console.log(i,strikePrice,mintAmount);
            if (mintAmount > needMint){
                let txError = false;
                try {
                    let txResult = await testCase.addCollateral(token.address,amount,mintAmount,account);
                } catch (error) {
                    txError = true;
                }
                assert(txError,"test insufficient collateral failed!");
            }else{
                let txResult = await testCase.addCollateral(token.address,amount,mintAmount,account);
                await checks[0].setTx(txResult);
                checks[0].addAccountCheckValue(account,-amount);
                checks[0].addAccountCheckValue(testCase.manager.address,amount);
                check1.addAccountCheckValue(account,mintAmount);
            }
        }        
    }
    for (var i=0;i<checks.length;i++){
        await checks[i].checkFunction();
    }
}

async function testAddcollateralTwice(collateral,testCase,expiration,optType,amount,account){
    let underlyingAsset = 1;
    let ethCheck = new checkBalance("collateral",[],testCase.oracle);
    if (collateral != collateral0){
        ethCheck.token = await IERC20.at(collateral); 
    }
    ethCheck.addAccount(account);
    ethCheck.addAccount(testCase.manager.address);
    await ethCheck.beforeFunction();
    let strikePrice = await testCase.getStrikePrice(underlyingAsset,1.1);
    let token = await testCase.createOptionsToken(collateral,underlyingAsset,expiration,optType,strikePrice,ethCheck);
    let needMint = await testCase.calCollateralToMintAmount(token.address,amount,optType);
    let mintAmount = Math.floor(needMint/2);
    let ercToken = await IERC20.at(token.address);
    let tokenCheck = new checkBalance("token",ethCheck.accounts,testCase.oracle,ercToken);
    await tokenCheck.beforeFunction();
    let txResult = await testCase.addCollateral(token.address,amount,mintAmount,account);
    await ethCheck.setTx(txResult);
    tokenCheck.addAccountCheckValue(account,mintAmount);
    ethCheck.addAccountCheckValue(account,-amount);
    ethCheck.addAccountCheckValue(testCase.manager.address,amount);
    txResult = await testCase.addCollateral(token.address,0,mintAmount,account);
    await ethCheck.setTx(txResult);
    tokenCheck.addAccountCheckValue(account,mintAmount);

    await ethCheck.checkFunction();
    await tokenCheck.checkFunction();
}

async function testWithdrawCollateralAndBurnToken(collateral,testCase,expiration,optType,amount,account){
    let underlyingAsset = 1;
    let ethCheck = new checkBalance("collateral",[],testCase.oracle);
    if (collateral != collateral0){
        ethCheck.token = await IERC20.at(collateral); 
    }
    ethCheck.addAccount(account);
    ethCheck.addAccount(testCase.manager.address);
    await ethCheck.beforeFunction();
    let strikePrice = await testCase.getStrikePrice(underlyingAsset,1.1);
    let token = await testCase.createOptionsToken(collateral,underlyingAsset,expiration,optType,strikePrice,ethCheck);
    let needMint = await testCase.calCollateralToMintAmount(token.address,amount,optType);
    let ercToken = await IERC20.at(token.address);
    let tokenCheck = new checkBalance("token",ethCheck.accounts,testCase.oracle,ercToken);
    await tokenCheck.beforeFunction();
    let txResult = await testCase.addCollateral(token.address,amount*2,needMint,account);
    await ethCheck.setTx(txResult);
    tokenCheck.addAccountCheckValue(account,needMint);
    ethCheck.addAccountCheckValue(account,-amount*2);
    ethCheck.addAccountCheckValue(testCase.manager.address,amount*2);
    txResult = await testCase.withdrawCollateral(collateral,amount,account);
    await ethCheck.setTx(txResult);
    ethCheck.addAccountCheckValue(account,amount);
    ethCheck.addAccountCheckValue(testCase.manager.address,-amount);

    txResult = await testCase.burnOptionsToken(token.address,needMint,account);
    await ethCheck.setTx(txResult);
    tokenCheck.addAccountCheckValue(account,-needMint);

    txResult = await testCase.withdrawCollateral(collateral,amount,account);
    await ethCheck.setTx(txResult);
    ethCheck.addAccountCheckValue(account,amount);
    ethCheck.addAccountCheckValue(testCase.manager.address,-amount);

    await ethCheck.checkFunction();
    await tokenCheck.checkFunction();
}