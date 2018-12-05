// Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// You may not use this file except in compliance with the License.
// A copy of the License is located at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// or in the "license" file accompanying this file. This file is distributed
// on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either
// express or implied. See the License for the specific language governing
// permissions and limitations under the License.
//
//  HTTPClient.swift
//  SmokeHTTPClient
//

import Foundation
import NIO
import NIOHTTP1
import NIOOpenSSL
import NIOTLS
import LoggerAPI

public class HTTPClient {
    /// The server hostname to contact for requests from this client.
    public let endpointHostName: String
    /// The server port to connect to.
    public let endpointPort: Int
    /// The content type of the payload being sent.
    public let contentType: String
    /// Delegate that provides client-specific logic for handling HTTP requests
    public let clientDelegate: HTTPClientDelegate
    /// The connection timeout in seconds
    public let connectionTimeoutSeconds: Int
    
    static let unexpectedClosureType =
        HTTPError.connectionError("Http request was unexpectedly closed without returning a response.")

    /// The event loop used by requests/responses from this client
    let eventLoopGroup: MultiThreadedEventLoopGroup

    /**
     Initializer.

     - Parameters:
     - endpointHostName: The server hostname to contact for requests from this client.
     - endpointPort: The server port to connect to.
     - contentType: The content type of the payload being sent by this client.
     - clientDelegate: Delegate for the HTTP client that provides client-specific logic for handling HTTP requests.
     - channelInboundHandlerDelegate: Delegate for the HTTP channel inbound handler that provides client-specific logic
     -                                around HTTP request/response settings.
     - connectionTimeoutSeconds: The time in second the client should wait for a response. The default is 10 seconds.
     */
    public init(endpointHostName: String,
                endpointPort: Int,
                contentType: String,
                clientDelegate: HTTPClientDelegate,
                connectionTimeoutSeconds: Int = 10) {
        self.endpointHostName = endpointHostName
        self.endpointPort = endpointPort
        self.contentType = contentType
        self.clientDelegate = clientDelegate
        self.connectionTimeoutSeconds = connectionTimeoutSeconds

        self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    }

    /**
     De-initializer. Shuts down the event loop group when this instance is deallocated.
     */
    deinit {
        do {
            try eventLoopGroup.syncShutdownGracefully()
        } catch {
            Log.error("Unable to shut down event loop group: \(error)")
        }
    }
    
    /**
     Gracefully shuts down the eventloop if owned by this client.
     */
    public func close() {
        // TODO: Move event loop shutdown from deinit
    }
    
    /**
     Waits for the client to be closed. If stop() is not called,
     this will block forever.
     */
    public func wait() {
        
    }

    func executeAsync<InputType>(
            endpointOverride: URL? = nil,
            endpointPath: String,
            httpMethod: HTTPMethod,
            input: InputType,
            completion: @escaping (HTTPResult<HTTPResponseComponents>) -> (),
            handlerDelegate: HTTPClientChannelInboundHandlerDelegate) throws -> Channel
            where InputType: HTTPRequestInputProtocol {

        let endpointHostName = endpointOverride?.host ?? self.endpointHostName
        let endpointPort = endpointOverride?.port ?? self.endpointPort

        let tlsConfiguration = clientDelegate.getTLSConfiguration()
        let sslContext = try SSLContext(configuration: tlsConfiguration)
        let sslHandler = try OpenSSLClientHandler(context: sslContext,
                                                  serverHostname: endpointHostName)

        let requestComponents = try clientDelegate.encodeInputAndQueryString(
            input: input,
            httpPath: endpointPath)

        let pathWithQuery = requestComponents.pathWithQuery

        let endpoint = "https://\(endpointHostName):\(endpointPort)\(pathWithQuery)"
        let sendPath = pathWithQuery
        let sendBody = requestComponents.body
        let additionalHeaders = requestComponents.additionalHeaders

        guard let url = URL(string: endpoint) else {
            throw HTTPError.invalidRequest("Request endpoint '\(endpoint)' not valid URL.")
        }

        Log.verbose("Sending \(httpMethod) request to endpoint: \(endpoint) at path: \(sendPath).")

        let handler = HTTPClientChannelInboundHandler(contentType: contentType,
                                                      endpointUrl: url,
                                                      endpointPath: sendPath,
                                                      httpMethod: httpMethod,
                                                      bodyData: sendBody,
                                                      additionalHeaders: additionalHeaders,
                                                      errorProvider: clientDelegate.getResponseError,
                                                      completion: completion,
                                                      channelInboundHandlerDelegate: handlerDelegate)

        let bootstrap = ClientBootstrap(group: eventLoopGroup)
            .connectTimeout(TimeAmount.seconds(self.connectionTimeoutSeconds))
            .channelInitializer { channel in
                channel.pipeline.add(handler: sslHandler).then {
                    channel.pipeline.addHTTPClientHandlers().then {
                        channel.pipeline.add(handler: handler)
                    }
                }
        }

        return try bootstrap.connect(host: endpointHostName, port: endpointPort).wait()
    }
}
