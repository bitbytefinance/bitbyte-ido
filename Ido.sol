// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import '../libs/Math.sol';
import '../libs/SafeMath.sol';
import '../libs/SafeERC20.sol';
import '../libs/SafeCast.sol';
import '../libs/TransferHelper.sol';
import '../libs/IRlinkCore.sol';
import '../libs/ReentrancyGuard.sol';
import './interfaces/IIdo.sol';

interface IIdoFactory {
    function rlink() external view returns(address);

    function feeOf(address _ido) external view returns(uint);

    function feeTo() external view returns(address);

    // function isAdmin(address account) external view returns(bool);

    function owner() external view returns(address);
}

contract Ido is ReentrancyGuard,IIdo {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public rewardToken;
    uint public rewardAmount;
    address public targetToken;
    uint public targetAmount;
    uint public softTop;
    uint public deadline;
    uint public minPayAmount;
    uint public maxPayAmount;
    address public creator;
    uint public fundAmount;
    uint public parentRate; 
    uint public grandpaRate;
    uint public startTime;

    uint public allPartnerLength;
    mapping(uint => address) public partners;
    mapping(address => uint) public partnerRateOf;
    mapping(address => uint) public partnerPaidOf;
    uint public unusedReserve;
    uint public takedAmount;
    uint public paidFee;

    uint public totalAccount;
    uint public totalClaimedAccount;
    mapping(address => uint) public investOf;
    mapping(address=> uint) public  userPaid;
    
    Release public release;

    address public immutable factory; 

    struct Release {
        uint128  startTime;
        uint64   times;
        uint64   interval;
    }
    
    event PartiCipated(address user,uint256 tokenamount,address tokenaddre);
    event WithDrawedTargetToken(address caller,uint amount);
    event ClaimedRewards(address caller,uint reward,uint parentAmount);
    event TakedRewardToken(address caller,uint amount);
    event WithdrawedInvest(address caller,uint amount);
    event FeePaid(address feeTo,address token, uint amount);

    // receive() external payable {
    // }

    modifier onlyFactoryOwner {
        require(msg.sender == IIdoFactory(factory).owner(),"forbidden");
        _;
    }    
    
    constructor () {
        factory = msg.sender;
    }

    function initialize(
        address _creator,
        address _rewardToken,
        address _targetToken,
        uint256[] memory _idoList,
        address[] memory _partners,
        uint256[] memory _partnerRates
    ) external override {
        require(msg.sender == factory,"initialize: forbidden");       

        IERC20(_rewardToken).safeApprove(IIdoFactory(factory).rlink(),type(uint256).max);

        rewardToken = _rewardToken;                    //  众筹代币类型
        rewardAmount = _idoList[0];                     // 众筹代币数量
        targetToken = _targetToken;                    // 募资目标token
        targetAmount = _idoList[1];                      // 募资token总额
        softTop = _idoList[2];                          // 软顶默认为0
        deadline = _idoList[6].add(_idoList[3]);             //开始时间戳+间隔秒计数 = 结束时间
        minPayAmount = _idoList[4];                           // 设置最低募资
        creator = _creator;                      // 受益人默认是合约的创建者
        parentRate = _idoList[7];        // 邀请返佣百分比 
        maxPayAmount = _idoList[5];                        // 设置最大购买限额
        startTime = _idoList[6];                       // 开始时间
        grandpaRate = _idoList[11];
    
        // 释放数据
        release = Release({
            startTime: SafeCast.toUint128(_idoList[8]),
            times: SafeCast.toUint64(_idoList[9]),
            interval: SafeCast.toUint64(_idoList[10])
        });

        // totalReserve =  _idoList[0].mul(1e18 + _idoList[7] + _idoList[11]).div(1e18);
     
        uint total = 0;
        for(uint i = 0; i < _partners.length; i++){
            total = total.add(_partnerRates[i]);
            require(total <= 1e18,"sum of partner rates must be 1e18");
            partnerRateOf[_partners[i]] = _partnerRates[i];
            partners[i] = _partners[i];                  
        }
        require(total == 1e18,"sum of partner rates must be 1e18");
        allPartnerLength = _partners.length;
    }

    // 当前余量
    function margin() external view returns(uint256){
        return targetAmount.sub(fundAmount);
    }    

    // 参与众筹
    // 是否在有效时间内
    // 参与募资数量不得小于设置数量
    // 参与数量 < 设置最大数
    function partiCipate(uint _tokenAmount) external payable nonReentrant {
        require(_tokenAmount > 0,"amount can not be 0");
        require(block.timestamp >= startTime,"not started"); 
        require(!_isEnded(),"ended");
        uint targetAmount_ = targetAmount;
        uint fundAmount_ = fundAmount;
        require(fundAmount_.add(_tokenAmount) <= targetAmount_,"time is up or the pool is full");  //时间是否结束或者当前数大于硬顶
        require(_tokenAmount >= minPayAmount || _tokenAmount == targetAmount_.sub(fundAmount_),"amount can not less than min pay amount");
        uint investedAmount = investOf[msg.sender];
        uint availQuota = Math.min(maxPayAmount.sub(investedAmount),targetAmount_.sub(fundAmount_));
        require(_tokenAmount <= availQuota,"insufficient available quota");  // 参数数大于最低限额  // 参与数小于设定最大数

        address payToken_ = targetToken;
        uint receivedAmount = _tokenAmount;
        if(payToken_ == address(0)){
            require(msg.value == _tokenAmount,"invalid input value");
        }else{
            uint balanceBefore = IERC20(payToken_).balanceOf(address(this));
            IERC20(payToken_).safeTransferFrom(msg.sender,address(this),_tokenAmount);
            receivedAmount =  IERC20(payToken_).balanceOf(address(this)).sub(balanceBefore);
            require(receivedAmount > 0,"no received token");
        }  

        fundAmount = fundAmount_.add(receivedAmount); 
        investOf[msg.sender] = investedAmount.add(receivedAmount);
        if(investedAmount == 0){
            totalAccount = totalAccount.add(1);
        }

        emit PartiCipated(msg.sender,receivedAmount,payToken_);
    }

    function takeRewardToken() external nonReentrant {
        require(msg.sender == creator,"caller must be creator");
        uint canTakeAmount = creatorCanTakeAmount();
        require(canTakeAmount > 0,"can take amount is 0");

        takedAmount = takedAmount.add(canTakeAmount);
        IERC20 rewardToken_ = IERC20(rewardToken);
        rewardToken_.safeTransfer(msg.sender,canTakeAmount);

        emit TakedRewardToken(msg.sender,canTakeAmount);
    }

    function withdrawInvest() external nonReentrant {
        require(_isEnded() && !_isSuccess(),"not ended or successed"); // 当前数量小于软顶
        require(investOf[msg.sender] > 0,"no invest"); // 筛选未参与者
        //如果为收益人
        uint balance = investOf[msg.sender];
        require(balance > 0,"no balance");
        address payToken_ = targetToken;
        investOf[msg.sender] = 0;
        if(payToken_ == address(0)){
            TransferHelper.safeTransferETH(msg.sender,balance);                
        }else{
            IERC20(payToken_).safeTransfer(msg.sender,balance);
        }

        emit WithdrawedInvest(msg.sender,balance);
    }

    function withdrawTargetToken() external nonReentrant {
        require(_isEnded() && _isSuccess(),"not ended or not successful");
        uint rate = partnerRateOf[msg.sender];
        require(rate > 0,"caller must be partner");
        uint paidAmount = partnerPaidOf[msg.sender];
        uint feeAmount = fundAmount.mul(IIdoFactory(factory).feeOf(address(this))) / 1e18;
        uint amount =  fundAmount.sub(feeAmount).mul(rate).div(1e18).sub(paidAmount);
        partnerPaidOf[msg.sender] = paidAmount.add(amount);

        address targetToken_ = targetToken;
        _payFee(targetToken_,feeAmount);
        if(targetToken_ == address(0)){
            TransferHelper.safeTransferETH(msg.sender,amount);
        }else{
            IERC20(targetToken_).safeTransfer(msg.sender,amount);
        }

        emit WithDrawedTargetToken(msg.sender,amount);    
    }

    function _payFee(address _token,uint _feeAmount) internal {
        if(paidFee == 0){
            paidFee = _feeAmount;
            address feeTo_ = IIdoFactory(factory).feeTo();
            if(_token == address(0)){
                TransferHelper.safeTransferETH(feeTo_,_feeAmount);
            }else{
                IERC20(_token).safeTransfer(feeTo_,_feeAmount);
            }

            emit FeePaid(feeTo_,_token,_feeAmount);
        }
    }

    function _pastTimes(Release memory _release) internal view returns(uint){
        if(_release.interval == 0){
            return _release.times;
        }
        if(block.timestamp < _release.startTime){
            return 0;
        }

        return (Math.min(block.timestamp,_lastReleaseTime(_release)) - _release.startTime) / _release.interval + 1;
    }

    function _lastReleaseTime(Release memory _release) internal pure returns(uint){
        return _release.startTime + _release.times * _release.interval - _release.interval;
    }

    function claim() external nonReentrant {
        Release memory release_ = release;        
        require(_isEnded() && _isSuccess(),"not ended or not successful");
        require(release_.startTime <= block.timestamp,"release not start");

        address caller = msg.sender;
        uint balance = investOf[caller];
        require(balance > 0,"caller not participated");
        uint userTotalReward =  balance.mul(rewardAmount).div(targetAmount);
        uint pastTimes = _pastTimes(release_);

        uint releasedReward = pastTimes == release_.times ? userTotalReward : pastTimes.mul(userTotalReward).div(release_.times);
        uint reward = releasedReward.sub(userPaid[caller]);
        require(reward > 0,"no reward can claim");
        userPaid[caller] = releasedReward;

        uint parentAmount = reward.mul(parentRate) / 1e18;
        uint grandpaAmount = reward.mul(grandpaRate) / 1e18;
        uint distributeAmount = reward.add(parentAmount).add(grandpaAmount);
        address rewardToken_ = rewardToken;
        uint cost = IRlinkCore(IIdoFactory(factory).rlink()).distribute(rewardToken_,caller,reward.add(parentAmount).add(grandpaAmount),0,parentAmount,grandpaAmount);
        require(cost > 0,"distribute failed");
        if(cost < distributeAmount){
            unusedReserve = unusedReserve.add(distributeAmount - cost);
        }

        if(userTotalReward == releasedReward){
            totalClaimedAccount = totalClaimedAccount.add(1);            
            if(totalClaimedAccount == totalAccount){
                uint unusedReserve_ = unusedReserve; 
                if(unusedReserve_ > 0){
                    IERC20(rewardToken_).safeTransfer(creator,unusedReserve_);
                }
            }            
        }

        emit ClaimedRewards(caller,reward,parentAmount);
    }

    function _isSuccess() internal view returns(bool){
        return fundAmount >= softTop;        
    }

    function _isEnded() internal view returns(bool){
        return deadline <= block.timestamp;
    }

    function creatorCanTakeAmount() public view returns(uint){
        if(!_isEnded()){
            return 0;            
        }

        uint rewardAmount_ = rewardAmount;
        uint amount = _isSuccess() ? rewardAmount_ - rewardAmount_ * fundAmount / targetAmount : rewardAmount_;
        amount = amount.add(amount.mul(parentRate).div(1e18)).add(amount.mul(grandpaRate).div(1e18));
        return amount.sub(takedAmount);
    }

    // function _safeTransferETH(address to, uint value) internal {
    //     (bool success,) = to.call{value : value}(new bytes(0));
    //     require(success, 'TransferHelper: BNB_TRANSFER_FAILED');
    // }

    function setParentRates(uint _parentRate,uint _grandpaRate) external {
        require(msg.sender == creator || msg.sender == IIdoFactory(factory).owner(),"setParentRates: forbidden");
        parentRate = _parentRate;
        grandpaRate = _grandpaRate;
    }

    function setCreator(address _creator) external override onlyFactoryOwner {
        address oldCreator = creator;
        creator = _creator;
        partnerRateOf[creator] = partnerRateOf[oldCreator];
    }

    function takeToken(address token,address to,uint256 amount) external onlyFactoryOwner {
        require(token != address(0),"invalid token");
        require(amount > 0,"amount can not be 0");
        require(to != address(0) && !Address.isContract(to),"invalid to address");
        IERC20(token).safeTransfer(to, amount);
    }

    function takeETH(address to,uint256 amount) external onlyFactoryOwner {
        require(amount > 0,"amount can not be 0");
        require(address(this).balance>=amount,"insufficient balance");
        require(to != address(0) && !Address.isContract(to),"invalid to address");
        
        TransferHelper.safeTransferETH(to,amount);
    }

    // FunAmount 集资资金当前数量
    // TargetAmounts 目标集资资金数量(硬顶)
    // _SoftTops 最低投入数
    function getPoolsInfo() public view returns(uint256 _fundAmount,uint256 _targetAmount,uint256 _softTop){
        _fundAmount = fundAmount;
        _targetAmount = targetAmount;
        _softTop = softTop;
    }

    // ido合约基础信息
    function idoInf() public view returns(
        uint TokensAmounts,
        uint TargetAmounts,
        uint SoftTops,
        uint Deadlines,
        uint Lowests,
        uint FunAmounts,
        uint Rebates,
        uint MxaAmounts,
        uint ReleaseTimts,
        uint Frequencys,
        uint freeddays,
        uint CreationTimes,
        address TokenRewards,
        address TargetTokens
    ){
        TokensAmounts = rewardAmount;
        TargetAmounts = targetAmount;
        SoftTops = softTop;
        Deadlines = deadline;
        Lowests = minPayAmount;
        FunAmounts = fundAmount;
        Rebates = parentRate;
        MxaAmounts = maxPayAmount;
        ReleaseTimts = release.startTime;
        Frequencys = release.times;
        freeddays = release.interval;
        CreationTimes = startTime;
        TokenRewards = rewardToken;
        TargetTokens = targetToken;
    }

    function infos(address account) external view returns(uint _unlockedAmount,uint _rewardAmount,uint _lockedAmount,uint _nextUnlockTime,uint _claimedAmount,uint _investAmount){
        _claimedAmount = userPaid[account];
        Release memory release_ = release;
        _investAmount = investOf[account];
        if(_investAmount > 0 && _isEnded() && _isSuccess()){
            uint userTotalReward = _investAmount.mul(rewardAmount).div(targetAmount);
            if(release_.startTime <= block.timestamp){
                uint pastTimes = _pastTimes(release_);
                _unlockedAmount = pastTimes == release_.times ? userTotalReward : pastTimes.mul(userTotalReward).div(release_.times);
                _rewardAmount = _unlockedAmount.sub(_claimedAmount);
            }
            _lockedAmount = userTotalReward - _unlockedAmount;
        }

        _nextUnlockTime = release_.startTime;
        if(block.timestamp > release_.startTime && release_.interval > 0){
            uint lastReleaseTime = _lastReleaseTime(release_);
            if(block.timestamp >= lastReleaseTime){
                _nextUnlockTime = lastReleaseTime;
            }else{
                uint mod = (block.timestamp - release_.startTime) % release_.interval;
                _nextUnlockTime = mod > 0 ? block.timestamp + release_.interval - mod : block.timestamp;
            }
        }        
    }

    function partnerInfos() external view returns(uint256 _fundAmount,uint256 _targetAmount,uint256 _softTop,uint _canTakeAmount, address[] memory _partners,uint[] memory _partnerRates,uint[] memory _paidAmounts) {
        _fundAmount = fundAmount.sub(fundAmount.mul(IIdoFactory(factory).feeOf(address(this))) / 1e18);
        _targetAmount = targetAmount;
        _softTop = softTop;
        _canTakeAmount = creatorCanTakeAmount();

        uint plen = allPartnerLength;
        _partners = new address[](plen);
        _partnerRates = new uint[](plen);
        _paidAmounts = new uint[](plen);
        for(uint i=0;i<plen;i++){
            _partners[i] = partners[i];
            _partnerRates[i] = partnerRateOf[_partners[i]];
            _paidAmounts[i] = partnerPaidOf[_partners[i]];
        }
    }    
}

