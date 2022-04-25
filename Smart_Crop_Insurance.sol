pragma solidity ^0.4.0;
// pragma experimental ABIEncoderV2;


//Remix imports - used when testing in remix 
import "https://github.com/smartcontractkit/chainlink/blob/develop/contracts/src/v0.4/ChainlinkClient.sol";
import "https://github.com/smartcontractkit/chainlink/blob/develop/contracts/src/v0.4/vendor/Ownable.sol";
import "https://github.com/smartcontractkit/chainlink/blob/develop/contracts/src/v0.4/interfaces/LinkTokenInterface.sol";
import "https://github.com/smartcontractkit/chainlink/blob/develop/contracts/src/v0.4/interfaces/AggregatorInterface.sol";
import "https://github.com/smartcontractkit/chainlink/blob/develop/contracts/src/v0.4/vendor/SafeMathChainlink.sol";
import "https://github.com/smartcontractkit/chainlink/blob/develop/contracts/src/v0.4/interfaces/AggregatorV3Interface.sol";




contract InsuranceProvider {
    
    using SafeMathChainlink for uint;
    address public insurer = msg.sender;
    AggregatorV3Interface internal priceFeed;

    uint public constant DAY_IN_SECONDS = 60; //How many seconds in a day. 60 for testing, 86400 for Production
    
    uint256 constant private ORACLE_PAYMENT = 0.1 * 10**18; // 0.1 LINK
    address public constant LINK_KOVAN = 0xa36085F69e2889c224210F603D836748e7dC0088 ; //address of LINK token on Kovan
    
    mapping (address => InsuranceContract) contracts; 
    
    
    constructor() public payable {
        priceFeed = AggregatorV3Interface(0x9326BFA02ADD2366b30bacB125260Af641031331);
    }

   
    modifier onlyOwner() {
		require(insurer == msg.sender,'Only Insurance provider can do this');
        _;
    }
    

      
    event contractCreated(address _insuranceContract, uint _premium, uint _totalCover);
    
    
    function newContract(address _client, uint _duration, uint _premium, uint _payoutValue, string _cropLocation) public payable onlyOwner() returns(address) {
        
        InsuranceContract i = (new InsuranceContract).value((_payoutValue * 1 ether).div(uint(getLatestPrice())))(_client, _duration, _premium, _payoutValue, _cropLocation, LINK_KOVAN,ORACLE_PAYMENT);
         
        contracts[address(i)] = i;  //store insurance contract in contracts Map
        
        emit contractCreated(address(i), msg.value, _payoutValue);
        
        LinkTokenInterface link = LinkTokenInterface(i.getChainlinkToken());
        link.transfer(address(i), ((_duration.div(DAY_IN_SECONDS)) + 2) * ORACLE_PAYMENT.mul(2));
        
        
        return address(i);
        
    }
    

  
    function getContract(address _contract) external view returns (InsuranceContract) {
        return contracts[_contract];
    }
    
    
    function updateContract(address _contract) external {
        InsuranceContract i = InsuranceContract(_contract);
        i.updateContract();
    }
    
    
    function getContractRainfall(address _contract) external view returns(uint) {
        InsuranceContract i = InsuranceContract(_contract);
        return i.getCurrentRainfall();
    }
    
    
    function getContractRequestCount(address _contract) external view returns(uint) {
        InsuranceContract i = InsuranceContract(_contract);
        return 3;
    }
    
    
    
   
    function getInsurer() external view returns (address) {
        return insurer;
    }
    
    
    
  
    function getContractStatus(address _address) external view returns (bool) {
        InsuranceContract i = InsuranceContract(_address);
        return false;
    }
    
   
    function getContractBalance() external view returns (uint) {
        return address(this).balance;
    }
    
    
    function endContractProvider() external payable onlyOwner() {
        LinkTokenInterface link = LinkTokenInterface(LINK_KOVAN);
        require(link.transfer(msg.sender, link.balanceOf(address(this))), "Unable to transfer");
        selfdestruct(insurer);
    }
    
    /**
     * Returns the latest price
     */
    function getLatestPrice() public view returns (int) {
        (,int price,,uint timeStamp,) = priceFeed.latestRoundData();
        // If the round is not complete yet, timestamp is 0
        require(timeStamp > 0, "Round not complete");
        return price;
    }
    
    /**
     * @dev fallback function, to receive ether
     */
    
    function() external payable {}

}

contract InsuranceContract is ChainlinkClient, Ownable  {
    
    using SafeMathChainlink for uint;
    AggregatorV3Interface internal priceFeed;
    
    uint public constant DAY_IN_SECONDS = 60; //How many seconds in a day. 60 for testing, 86400 for Production
    uint public constant DROUGHT_DAYS_THRESDHOLD = 3 ;  //Number of days without rainfall to be defined as a drought
    uint256 private oraclePaymentAmount;

    address public insurer;
    address  client;
    uint startDate;
    uint duration;
    uint premium;
    uint payoutValue;
    string cropLocation;
    

    uint256[2] public currentRainfallList;
    bytes32[2] public jobIds;
    address[2] public oracles;
    
    string constant WORLD_WEATHER_ONLINE_URL = "http://api.worldweatheronline.com/premium/v1/weather.ashx?";
    string constant WORLD_WEATHER_ONLINE_KEY = "70e0462f46674ecb859154556221704";
    string constant WORLD_WEATHER_ONLINE_PATH = "data.current_condition.0.precipMM";
    
    string constant OPEN_WEATHER_URL = "https://openweathermap.org/data/2.5/weather?";
    string constant OPEN_WEATHER_KEY = "7ed1d3bd34264df946c296767a5c20b8";
    string constant OPEN_WEATHER_PATH = "rain.1h";
    
    string constant WEATHERBIT_URL = "https://api.weatherbit.io/v2.0/current?";
    string constant WEATHERBIT_KEY = "1e5aaaca67634bc0bb9400e088bbbaea";
    string constant WEATHERBIT_PATH = "data.0.precip";
    
    uint daysWithoutRain;                   //how many days there has been with 0 rain
    bool contractActive;                    //is the contract currently active, or has it ended
    bool contractPaid = false;
    uint currentRainfall = 0;               //what is the current rainfall for the location
    uint currentRainfallDateChecked = now;  //when the last rainfall check was performed
    uint requestCount = 0;                  //how many requests for rainfall made
    uint dataRequestsSent = 0;             //variable used to determine if both requests have been sent or not
    

    
    modifier onlyOwner() {
		require(insurer == msg.sender,'Only Insurance provider can do this');
        _;
    }
    
    
    modifier onContractEnded() {
        if (startDate + duration < now) {
          _;  
        } 
    }
    
    
    modifier onContractActive() {
        require(contractActive == true ,'Contract has ended, cant interact with it anymore');
        _;
    }

      
    modifier callFrequencyOncePerDay() {
        require(now.sub(currentRainfallDateChecked) > (DAY_IN_SECONDS.sub(DAY_IN_SECONDS.div(12))),'Can only check rainfall once per day');
        _;
    }
    
    event contractCreated(address _insurer, address _client, uint _duration, uint _premium, uint _totalCover);
    event contractPaidOut(uint _paidTime, uint _totalPaid, uint _finalRainfall);
    event contractEnded(uint _endTime, uint _totalReturned);
    event ranfallThresholdReset(uint _rainfall);
    event dataRequestSent(bytes32 requestId);
    event dataReceived(uint _rainfall);

    
    constructor(address _client, uint _duration, uint _premium, uint _payoutValue, string _cropLocation, 
                address _link, uint256 _oraclePaymentAmount)  payable Ownable() public {
        
       
        priceFeed = AggregatorV3Interface(0x9326BFA02ADD2366b30bacB125260Af641031331);
        
        setChainlinkToken(_link);
        oraclePaymentAmount = _oraclePaymentAmount;
    
        require(msg.value >= _payoutValue.div(uint(getLatestPrice())), "Not enough funds sent to contract");
        
        insurer= msg.sender;
        client = _client;
        startDate = now ; 
        duration = _duration;
        premium = _premium;
        payoutValue = _payoutValue;
        daysWithoutRain = 0;
        contractActive = true;
        cropLocation = _cropLocation;
        
        
        
        
        oracles[0] = 0x240BaE5A27233Fd3aC5440B5a598467725F7D1cd;
        oracles[1] = 0x5b4247e58fe5a54A116e4A3BE32b31BE7030C8A3;
        jobIds[0] = '1bc4f827ff5942eaaa7540b7dd1e20b9';
        jobIds[1] = 'e67ddf1f394d44e79a9a2132efd00050';
        
        emit contractCreated(insurer,
                             client,
                             duration,
                             premium,
                             payoutValue);
    }
    
   
    function updateContract() public onContractActive() {
        checkEndContract();
        
        if (contractActive) {
            dataRequestsSent = 0;
            //World Weather Online to get the current rainfall
            string memory url = string(abi.encodePacked(WORLD_WEATHER_ONLINE_URL, "key=",WORLD_WEATHER_ONLINE_KEY,"&q=",cropLocation,"&format=json&num_of_days=1"));
            checkRainfall(oracles[0], jobIds[0], url, WORLD_WEATHER_ONLINE_PATH);

            
            // request to WeatherBit
            url = string(abi.encodePacked(WEATHERBIT_URL, "city=",cropLocation,"&key=",WEATHERBIT_KEY));
            checkRainfall(oracles[1], jobIds[1], url, WEATHERBIT_PATH);    
        }
    }
    
    /**
     * Oracle for obtaining weather data
     */ 
    function checkRainfall(address _oracle, bytes32 _jobId, string _url, string _path) private onContractActive() returns (bytes32 requestId)   {

        //First build up a request to get the current rainfall
        Chainlink.Request memory req = buildChainlinkRequest(_jobId, address(this), this.checkRainfallCallBack.selector);
           
        req.add("get", _url); //sends the GET request to the oracle
        req.add("path", _path);
        req.addInt("times", 100);
        
        requestId = sendChainlinkRequestTo(_oracle, req, oraclePaymentAmount); 
            
        emit dataRequestSent(requestId);
    }
    
    
    function checkRainfallCallBack(bytes32 _requestId, uint256 _rainfall) public recordChainlinkFulfillment(_requestId) onContractActive() callFrequencyOncePerDay()  {
       currentRainfallList[dataRequestsSent] = _rainfall; 
       dataRequestsSent = dataRequestsSent + 1;
       
       
       if (dataRequestsSent > 1) {
          currentRainfall = (currentRainfallList[0].add(currentRainfallList[1]).div(2));
          currentRainfallDateChecked = now;
          requestCount += 1;
    
          if (currentRainfall == 0 ) {
              daysWithoutRain += 1;
          } else {
              daysWithoutRain = 0;
              emit ranfallThresholdReset(currentRainfall);
          }
       
          if (daysWithoutRain >= DROUGHT_DAYS_THRESDHOLD) {
              payOutContract();
          }
       }
       
       emit dataReceived(_rainfall);
        
    }
    
     
    function payOutContract() private onContractActive()  {
        
        
        client.transfer(address(this).balance);    
        LinkTokenInterface link = LinkTokenInterface(chainlinkTokenAddress());
        require(link.transfer(insurer, link.balanceOf(address(this))), "Unable to transfer");
        
        emit contractPaidOut(now, payoutValue, currentRainfall);
        
        contractActive = false;
        contractPaid = true;
    
    }  
    
    /**
     * Insurance conditions
     */ 
    function checkEndContract() private onContractEnded()   {
        
        if (requestCount >= (duration.div(DAY_IN_SECONDS) - 2)) {
            
            insurer.transfer(address(this).balance);
        } else { 
            client.transfer(premium.div(uint(getLatestPrice())));
            insurer.transfer(address(this).balance);
        }
        
        //transfer any remaining LINK tokens back to the insurer
        LinkTokenInterface link = LinkTokenInterface(chainlinkTokenAddress());
        require(link.transfer(insurer, link.balanceOf(address(this))), "Unable to transfer remaining LINK tokens");
        
        //mark contract as ended, so no future state changes can occur on the contract
        contractActive = false;
        emit contractEnded(now, address(this).balance);
    }
    
    /**
     * the latest price of ETH to USD
     */
    function getLatestPrice() public view returns (int) {
        (,int price,,uint timeStamp,) = priceFeed.latestRoundData();
        // If the round is not complete yet, timestamp is 0
        require(timeStamp > 0, "Round not complete");
        return price;
    }
    
    
    /**
     * Gives the balance of the contract
     */ 
    function getContractBalance() external view returns (uint) {
        return address(this).balance;
    } 
    
    /**
     * Crop Location
     */ 
    function getLocation() external view returns (string) {
        return cropLocation;
    } 
    
    
    function getPayoutValue() external view returns (uint) {
        return payoutValue;
    } 
    
    
    /**
     * Premium
     */ 
    function getPremium() external view returns (uint) {
        return premium;
    } 
    
    /**
     * status of contract
     */ 
    function getContractStatus() external view returns (bool) {
        return contractActive;
    }
    
    /**
     * whether the contract has been paid or not
     */ 
    function getContractPaid() external view returns (bool) {
        return contractPaid;
    }
    
    
    /**
     * current rainfall 
     */ 
    function getCurrentRainfall() external view returns (uint) {
        return currentRainfall;
    }
    
    /**
     * No. of days without rain
     */ 
    function getDaysWithoutRain() external view returns (uint) {
        return daysWithoutRain;
    }
    
    /**
     * count of requests
     */ 
    function getRequestCount() external view returns (uint) {
        return requestCount;
    }
    
    /**
     * last time the rainfallchack for the contract
     */ 
    function getCurrentRainfallDateChecked() external view returns (uint) {
        return currentRainfallDateChecked;
    }
    
    
     
    function getDuration() external view returns (uint) {
        return duration;
    }
    
    
    function getContractStartDate() external view returns (uint) {
        return startDate;
    }
    
    
    function getNow() external view returns (uint) {
        return now;
    }
    
    
    function getChainlinkToken() public view returns (address) {
        return chainlinkTokenAddress();
    }
    
    
    function stringToBytes32(string memory source) private pure returns (bytes32 result) {
        bytes memory tempEmptyStringTest = bytes(source);
        if (tempEmptyStringTest.length == 0) {
         return 0x0;
        }

        assembly { 
        result := mload(add(source, 32))
        }
    }
    
    
    function uint2str(uint _i) internal pure returns (string memory _uintAsString) {
        if (_i == 0) {
            return "0";
        }
        uint j = _i;
        uint len;
        while (j != 0) {
            len++;
            j /= 10;
        }
        bytes memory bstr = new bytes(len);
        uint k = len - 1;
        while (_i != 0) {
            bstr[k--] = byte(uint8(48 + _i % 10));
            _i /= 10;
        }
        return string(bstr);
    }
    
    function() external payable {  }

    
}



