redis = require 'redis'
crypto = require 'crypto'
postal = require 'postal'

config = require '../config'
log = require './bbblogger'

module.exports = class RedisPubSub

  constructor: ->
    @pubClient = redis.createClient()
    @subClient = redis.createClient()

    # hash to store requests waiting for response
    @pendingRequests = {}

    postal.subscribe
      channel: config.redis.internalChannels.publish
      topic: 'broadcast'
      callback: (msg, envelope) =>
        if envelope.replyTo?
          @sendAndWaitForReply(msg, envelope)
        else
          @send(msg, envelope)

    @subClient.on "psubscribe", @_onSubscribe
    @subClient.on "pmessage", @_onMessage

    log.info("RPC: Subscribing message on channel: #{config.redis.channels.fromBBBApps}")
    @subClient.psubscribe(config.redis.channels.fromBBBApps)

  # Sends a message and waits for a reply
  sendAndWaitForReply: (message, envelope) ->
    # generate a unique correlation id for this call
    correlationId = crypto.randomBytes(16).toString('hex')

    # create a timeout for what should happen if we don't get a response
    timeoutId = setTimeout( (correlationId) =>
      response = {}
      # if this ever gets called we didn't get a response in a timely fashion
      response.err =
        code: "503"
        message: "Waiting for reply timeout."
        description: "Waiting for reply timeout."
      postal.publish
        channel: envelope.replyTo.channel
        topic: envelope.replyTo.topic
        data: response
      # delete the entry from hash
      delete @pendingRequests[correlationId]
    , config.redis.timeout, correlationId)

    # create a request entry to store in a hash
    entry =
      replyTo: envelope.replyTo
      timeout: timeoutId #the id for the timeout so we can clear it

    # put the entry in the hash so we can match the response later
    @pendingRequests[correlationId] = entry
    message.header.replyTo = correlationId

    log.info({ message: message }, "Publishing a message")
    @pubClient.publish(config.redis.channels.toBBBApps, JSON.stringify(message))

  # Send a message without waiting for a reply
  send: (message, envelope) ->
    # TODO

  _onSubscribe: (channel, count) =>
    log.info("Subscribed to #{channel}")

  _onMessage: (pattern, channel, jsonMsg) =>
    log.debug({ pattern: pattern, channel: channel, message: jsonMsg}, "Received a message from redis")
    # TODO: this has to be in a try/catch block, otherwise the server will
    #   crash if the message has a bad format
    message = JSON.parse(jsonMsg)

    # retrieve the request entry
    correlationId = message.header?.replyTo
    if correlationId? and @pendingRequests?[correlationId]?
      entry = @pendingRequests[correlationId]
      # make sure the message in the timeout isn't triggered by clearing it
      clearTimeout(entry.timeout)

      delete @pendingRequests[correlationId]
      postal.publish
        channel: entry.replyTo.channel
        topic: entry.replyTo.topic
        data: message
    else
      sendToController(message)

sendToController = (message) ->
  postal.publish
    channel: config.redis.internalChannels.receive
    topic: "broadcast"
    data: message