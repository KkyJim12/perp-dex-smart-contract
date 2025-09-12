// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract User {
    struct UserInfo {
        string username;
    }

    mapping(address => UserInfo) public users;

    event RegisterUser(address indexed userAddress, string username);

    function registerUser(string calldata username) external {
        require(bytes(username).length > 0, "Username cannot be empty");
        require(
            bytes(users[msg.sender].username).length == 0,
            "User already registered"
        );
        users[msg.sender] = UserInfo(username);
        emit RegisterUser(msg.sender, username);
    }
}
