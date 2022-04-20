// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import '../libs/CfoTakeable.sol';
import '../libs/ReentrancyGuard.sol';
import './ido.sol';

contract IdoFactory is CfoTakeable,ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    mapping(uint256 => address) public idos;
    mapping(address => bool) public isSpecialFee;
    mapping(address => uint256) public specialFeeOf;

    uint public globalCommissionFee = 25 * 1e15;
    address public feeTo;

    uint public fees;
    uint public maxDuration;
    address public immutable rlink;

    uint nonce = 1;

    event createidos(address newidos,uint256 projectNo);

    receive() external payable {        
    }
      
    constructor (
        address _rlink
    ) {

        rlink = _rlink;

        fees = 2 * 1e17;
        maxDuration = 365 * 86400;
        feeTo = address(0x0a1A7829C8300739A125cF41eE39255d1806663D);
    }

    // _idoList[0]: total reawrds
    // _idoList[1]: target amount
    // _idoList[2]: soft top
    // _idoList[3]: duration
    // _idoList[4]: min pay amount
    // _idoList[5]: max pay amount
    // _idoList[6]: start time
    // _idoList[7]: parent rate
    // _idoList[8]: release start time
    // _idoList[9]: release times
    // _idoList[10]: release interval
    // _idoList[11]: grandpa rate    
    function createido(
        uint _projectNo,
        address _rewardToken,
        address _targetToken,
        uint256[] memory _idoList,
        address[] memory _partners,
        uint256[] memory _partnerRates
    ) public payable nonReentrant {
        require(msg.value >= fees,"not enough input value");
        if(msg.value > 0 && feeTo != address(this)){
            TransferHelper.safeTransferETH(feeTo,msg.value);
        }
    
        // require(_projectNo > 0,"_projectNo can not be 0");
        require(_projectNo > 0 && idos[_projectNo] == address(0),"invalid _projectNo");
        require(_idoList.length == 12,"invalid _idoList length");
        // require(_rewardToken != address(0),"_rewardToken can not be address 0");
        require(_rewardToken != address(0) && _rewardToken != _targetToken,"invalid reawrd token");
        require(_idoList[0] > 0,"total rewards can not be 0");
        require(_idoList[1] > 0,"target amount can not be 0");
        require(_idoList[2] <= _idoList[1],"invalid soft top");
        require(_idoList[3] > 0 && _idoList[3] <= maxDuration,"invalid duration");
        require(_idoList[4] <= _idoList[5],"invalid min pay amount");
        require(_idoList[5] <= _idoList[1],"invalid max pay amount");
        require(_idoList[6] >= block.timestamp,"invalid start time");
        require(_idoList[8] >= _idoList[6].add(_idoList[3]),"release time must grater than or equals to end time");
        require(_idoList[9] <= 1 || _idoList[10] > 0,"invalid release interval or times");
        require(_idoList[7].add(_idoList[11]) <= 1e18,"sum of parent rates can not greater than 1e18");

        require(_partners.length > 0,"_partners can not be empty");
        require(_partners.length == _partnerRates.length,"incorrect _partners length or _partnerRates length");

        if(_idoList[2] == 0)  _idoList[2] = _idoList[1];
        if(_idoList[5] == 0) _idoList[5] = _idoList[1];
        if(_idoList[9] == 0) _idoList[9] = 1;

        bytes memory bytecode = type(Ido).creationCode;
        bytes32 salt = keccak256(abi.encode(_projectNo,nonce++));
        address ido;
        assembly {
            ido := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }

        uint transferAmount = _idoList[0].mul(1e18 + _idoList[7] + _idoList[11]).div(1e18);
        IERC20(_rewardToken).safeTransferFrom(msg.sender,ido,transferAmount);
        require(IERC20(_rewardToken).balanceOf(ido) >= transferAmount,"insufficient received token");

        idos[_projectNo] = ido;

        IIdo(ido).initialize(
            msg.sender,
            _rewardToken,
            _targetToken,
            _idoList,
            _partners,
            _partnerRates
        );

        emit createidos(ido,_projectNo);
    }

    // function getfees() public view returns(uint256){
    //      return fees;
    // }

    // function setIdoCreator(address ido,address _creator) external onlyAdmin {
    //     require(ido != address(0),"ido can not be address 0");
    //     require(_creator != address(0),"creator can not be address 0");
    //     IIdo(ido).setCreator(_creator);
    // }

    // function setIdoParentRates(address ido,uint _parentRate,uint _grandpaRate) external onlyAdmin {
    //     require(ido != address(0),"ido can not be address 0");
    //     require(_parentRate.add(_grandpaRate) <= 1e18,"sum of parent rates can not greater than 1e18");

    //     IIdo(ido).setParentRates(_parentRate,_grandpaRate);
    // }

    // function takeIdoToken(address ido,address token,address to,uint256 amount) external onlyCfoOrOwner {
    //     require(ido != address(0),"ido can not be address 0");
    //     IIdo(ido).takeToken(token,to,amount);
    // }

    // function takeIdoETH(address ido,address to,uint256 amount) external onlyCfoOrOwner {
    //     require(ido != address(0),"ido can not be address 0");
    //     IIdo(ido).takeETH(to,amount);
    // }

    function feeOf(address _ido) external view returns(uint){
        return isSpecialFee[_ido] ? specialFeeOf[_ido] : globalCommissionFee;
    }

    function setFees(uint _createBNBFee,uint _globalCommissionfee) external onlyOwner {
        require(_globalCommissionfee <= 1e18,"fee cannot greater than 1e18");
        fees = _createBNBFee;
        globalCommissionFee = _globalCommissionfee;
    }

    function setFeeTo(address _feeTo) external onlyOwner {
        require(_feeTo != address(0),"_feeTo can not be address 0");
        feeTo = _feeTo;
    }

    function setSpecialFee(address _ido,uint _fee) public onlyOwner {
        require(_ido != address(0),"ido can not be address 0");
        require(_fee <= 1e18,"fee can not greater than 1e18");
        isSpecialFee[_ido] = true;
        specialFeeOf[_ido] = _fee;
    }

    function removeSpecialFee(address _ido) public onlyOwner {
        require(_ido != address(0),"ido can not be address 0");
        isSpecialFee[_ido] = false;
    }

    // function setRlink(address _rlink) public onlyAdmin {
    //    rlink = _rlink;
    // }
}
