import std/sequtils
import pkg/chronos
import pkg/chronos/unittest2/asynctests
import pkg/quic/errors
import pkg/quic/transport/stream
import pkg/quic/transport/quicconnection
import pkg/quic/transport/ngtcp2/native
import pkg/quic/udp/datagram
import ../helpers/simulation
import ../helpers/contains

suite "streams":
  setup:
    var (client, server) = waitFor performHandshake()

  teardown:
    waitFor client.drop()
    waitFor server.drop()

  asyncTest "opens uni-directional streams":
    let stream1, stream2 = await client.openStream(unidirectional = true)
    check stream1 != stream2
    check stream1.isUnidirectional
    check stream2.isUnidirectional

  asyncTest "opens bi-directional streams":
    let stream1, stream2 = await client.openStream()
    check stream1 != stream2
    check not stream1.isUnidirectional
    check not stream2.isUnidirectional

  asyncTest "closes stream":
    let stream = await client.openStream()
    await stream.close()

  asyncTest "writes zero-length message":
    let stream = await client.openStream()
    await stream.write(@[])
    let datagram = await client.outgoing.get()

    check datagram.len > 0

  asyncTest "raises when writing to closed stream":
    let stream = await client.openStream()
    await stream.close()

    expect QuicError:
      await stream.write(@[1'u8, 2'u8, 3'u8])

  asyncTest "raises when reading from or writing to reset stream":
    let stream = await client.openStream()
    stream.reset()
    expect QuicError:
      discard await stream.read()

    expect QuicError:
      await stream.write(@[1'u8, 2'u8, 3'u8])

  asyncTest "accepts incoming streams":
    let simulation = simulateNetwork(client, server)

    let clientStream = await client.openStream()
    await clientStream.write(@[])

    let serverStream = await server.incomingStream()
    check clientStream.id == serverStream.id

    await simulation.cancelAndWait()

  asyncTest "reads from stream":
    let simulation = simulateNetwork(client, server)
    let message = @[1'u8, 2'u8, 3'u8]

    let clientStream = await client.openStream()
    await clientStream.write(message)

    let serverStream = await server.incomingStream()
    check clientStream.id == serverStream.id

    let incoming = await serverStream.read()
    check incoming == message

    await simulation.cancelAndWait()

  asyncTest "writes long messages to stream":
    let simulation = simulateNetwork(client, server)

    let stream = await client.openStream()
    let message = repeat(42'u8, 100 * sizeof(Ngtcp2Connection.buffer))
    asyncSpawn stream.write(message)

    let incoming = await server.incomingStream()
    for _ in 0 ..< 100:
      discard await incoming.read()

    await simulation.cancelAndWait()

  asyncTest "halts sender until receiver has caught up":
    let simulation = simulateNetwork(client, server)
    let message = repeat(42'u8, sizeof(Ngtcp2Connection.buffer))

    # send until blocked
    let sender = await client.openStream()
    while true:
      if not await sender.write(message).withTimeout(100.milliseconds):
        break

    # receive until blocked
    let receiver = await server.incomingStream()
    while true:
      if not await receiver.read().withTimeout(100.milliseconds):
        break

    # check that sender is unblocked
    check await sender.write(message).withTimeout(100.milliseconds)

    await simulation.cancelAndWait()

  asyncTest "handles packet loss":
    let simulation = simulateLossyNetwork(client, server)

    let message = @[1'u8, 2'u8, 3'u8]
    let clientStream = await client.openStream()
    await clientStream.write(message)

    let serverStream = await server.incomingStream()
    let incoming = await serverStream.read()

    check incoming == message

    await simulation.cancelAndWait()

  asyncTest "stream behavior when peer closes":
    let simulation = simulateNetwork(client, server)

    let clientStream = await client.openStream()
    await clientStream.write(@[1'u8, 2'u8, 3'u8])

    let serverStream = await server.incomingStream()

    discard await serverStream.read()

    await clientStream.close()

    await sleepAsync(100.milliseconds) # wait for stream to be closed

    # Reading from a closed stream should return EOF, not throw exception
    let eof = await serverStream.read()
    check eof.len == 0 # Should return EOF (empty array)

    # In QUIC, receiving FIN doesn't prevent writing back (half-close semantics)
    # Writing should still work unless the local side is closed
    await serverStream.write(@[4'u8, 5'u8, 6'u8])

    # But after we close our side, writing should fail
    await serverStream.close()
    expect QuicError:
      await serverStream.write(@[7'u8, 8'u8, 9'u8])

    await simulation.cancelAndWait()

  asyncTest "closes stream when underlying connection is closed by peer":
    let simulation = simulateNetwork(client, server)

    let clientStream = await client.openStream()
    await clientStream.write(@[1'u8, 2'u8, 3'u8])

    let serverStream = await server.incomingStream()
    discard await serverStream.read()

    await client.close()
    await sleepAsync(100.milliseconds) # wait for connection to be closed

    check serverStream.isClosed

    await simulation.cancelAndWait()

  asyncTest "reads last bytes from stream that is closed by peer":
    let simulation = simulateNetwork(client, server)
    let message = @[1'u8, 2'u8, 3'u8]

    let clientStream = await client.openStream()
    await clientStream.write(message)
    await clientStream.close()
    await sleepAsync(100.milliseconds) # wait for stream to be closed

    let serverStream = await server.incomingStream()
    let incoming = await serverStream.read()
    check incoming == message

    await simulation.cancelAndWait()

  asyncTest "closeWrite() prevents further writes":
    let simulation = simulateNetwork(client, server)
    let message = @[1'u8, 2'u8, 3'u8]

    let clientStream = await client.openStream()
    await clientStream.write(message)
    await clientStream.closeWrite()

    # Writing after closeWrite should fail
    expect QuicError:
      await clientStream.write(@[4'u8, 5'u8, 6'u8])

    await simulation.cancelAndWait()

  asyncTest "closeWrite() sends FIN but allows server to write back":
    let simulation = simulateNetwork(client, server)
    let clientMessage = @[1'u8, 2'u8, 3'u8]
    let serverMessage = @[4'u8, 5'u8, 6'u8]

    # Client writes and closes write side
    let clientStream = await client.openStream()
    await clientStream.write(clientMessage)
    await clientStream.closeWrite()

    # Server reads client message
    let serverStream = await server.incomingStream()
    let incoming = await serverStream.read()
    check incoming == clientMessage

    # Server should still be able to write back
    await serverStream.write(serverMessage)

    # Client should be able to read server's response
    let response = await clientStream.read()
    check response == serverMessage

    await simulation.cancelAndWait()

  asyncTest "closeWrite() called on closed stream does nothing":
    let simulation = simulateNetwork(client, server)

    let clientStream = await client.openStream()
    await clientStream.close()

    # Calling closeWrite on already closed stream should not raise
    await clientStream.closeWrite()
    await simulation.cancelAndWait()

  asyncTest "writing on a stream closed for writing raises error":
    let simulation = simulateNetwork(client, server)

    let clientStream = await client.openStream()
    await clientStream.write(@[1'u8, 2'u8, 3'u8])
    await clientStream.close()

    expect QuicError:
      await clientStream.write(@[4'u8, 5'u8, 6'u8])

    await simulation.cancelAndWait()

  asyncTest "empty write + closeWrite pattern works":
    let simulation = simulateNetwork(client, server)

    let clientStream = await client.openStream()
    await clientStream.write(@[])
    await clientStream.closeWrite()

    await simulation.cancelAndWait()

  asyncTest "empty write + data + closeWrite (libp2p pattern) works":
    let simulation = simulateNetwork(client, server)
    var uploadData = @[1'u8, 2'u8, 3'u8, 4'u8, 5'u8]

    let clientStream = await client.openStream()
    await clientStream.write(@[])
    await clientStream.write(uploadData)
    await clientStream.closeWrite()

    let serverStream = await server.incomingStream()
    let received = await serverStream.read()
    check received == uploadData

    await simulation.cancelAndWait()

  asyncTest "multiple empty writes before closeWrite works":
    let simulation = simulateNetwork(client, server)

    let clientStream = await client.openStream()
    await clientStream.write(@[])
    await clientStream.write(@[])
    await clientStream.closeWrite()

    await simulation.cancelAndWait()

  asyncTest "closeWrite immediately after openStream works":
    let simulation = simulateNetwork(client, server)

    let clientStream = await client.openStream()
    await clientStream.closeWrite()

    await simulation.cancelAndWait()

  asyncTest "perf-like upload/download pattern works":
    let simulation = simulateNetwork(client, server)
    var uploadData = @[6'u8, 7'u8, 8'u8, 9'u8, 10'u8]

    let clientStream = await client.openStream()
    await clientStream.write(@[])
    await clientStream.write(uploadData)
    await clientStream.closeWrite()

    let serverStream = await server.incomingStream()
    let received = await serverStream.read()
    check received == uploadData

    # Server sends response back
    var downloadData = @[11'u8, 12'u8, 13'u8, 14'u8, 15'u8]
    await serverStream.write(downloadData)
    await serverStream.closeWrite()

    let response = await clientStream.read()
    check response == downloadData

    await simulation.cancelAndWait()

  asyncTest "large data transfers with empty write activation work":
    let simulation = simulateNetwork(client, server)
    var largeData = newSeq[uint8](1000)
    for i in 0 ..< 1000:
      largeData[i] = uint8(i mod 256)

    let clientStream = await client.openStream()
    await clientStream.write(@[])
    await clientStream.write(largeData)
    await clientStream.closeWrite()

    let serverStream = await server.incomingStream()
    let received = await serverStream.read()
    check received == largeData

    await simulation.cancelAndWait()

  asyncTest "multiple data chunks after empty write activation work":
    let simulation = simulateNetwork(client, server)
    var chunk1 = @[20'u8, 21'u8, 22'u8]
    var chunk2 = @[23'u8, 24'u8, 25'u8]
    var chunk3 = @[26'u8, 27'u8, 28'u8]

    let clientStream = await client.openStream()
    await clientStream.write(@[])
    await clientStream.write(chunk1)
    await clientStream.write(chunk2)
    await clientStream.write(chunk3)
    await clientStream.closeWrite()

    let serverStream = await server.incomingStream()
    var allReceived: seq[uint8]

    # Read all chunks
    let received1 = await serverStream.read()
    allReceived.add(received1)

    try:
      let received2 = await serverStream.read()
      allReceived.add(received2)
      let received3 = await serverStream.read()
      allReceived.add(received3)
    except:
      # May receive combined chunks due to TCP-like behavior
      discard

    var expectedData = chunk1 & chunk2 & chunk3
    check allReceived == expectedData

    await simulation.cancelAndWait()

  asyncTest "read() returns EOF after closeWrite()":
    let simulation = simulateNetwork(client, server)
    let testData = @[1'u8, 2'u8, 3'u8, 4'u8, 5'u8]

    # Client writes data and closes write side
    let clientStream = await client.openStream()
    await clientStream.write(testData)
    await clientStream.closeWrite()

    # Server reads data
    let serverStream = await server.incomingStream()
    let received = await serverStream.read()
    check received == testData

    # Second read should return EOF (empty array)
    let eof = await serverStream.read()
    check eof.len == 0 # EOF should be empty array

    # Third read should also return EOF
    let eof2 = await serverStream.read()
    check eof2.len == 0 # Multiple EOF reads should work

    await simulation.cancelAndWait()

  asyncTest "request-response pattern with half-close":
    let simulation = simulateNetwork(client, server)
    let request = cast[seq[byte]]("GET /\n")
    let response = cast[seq[byte]]("HTTP/1.1 200 OK\n")

    # Client sends request and closes write side (signals end of request)
    let clientStream = await client.openStream()
    await clientStream.write(request)
    await clientStream.closeWrite() # "I'm done sending the request"

    # Server receives the request  
    let serverStream = await server.incomingStream()
    let receivedRequest = await serverStream.read()
    check receivedRequest == request

    # Server detects end of request (EOF)
    let requestEof = await serverStream.read()
    check requestEof.len == 0 # End of request

    # Server processes and sends response (can still write back!)
    await serverStream.write(response)
    await serverStream.close() # Server finishes and closes completely

    # Client reads the response
    let receivedResponse = await clientStream.read()
    check receivedResponse == response

    # Client detects end of response
    let responseEof = await clientStream.read()
    check responseEof.len == 0 # End of response

    # At this point both sides have received what they need
    # Client can't write (closeWrite called), server can't write (close called)
    expect QuicError:
      await clientStream.write(@[ord('X').uint8])
        # Should fail - client closed write side

    await simulation.cancelAndWait()

  # Bidirectional stream closure tests
  asyncTest "close() should fully close bidirectional stream in both directions":
    ## RFC 9000: close() should fully close the stream (both read and write)
    let simulation = simulateNetwork(client, server)

    let clientStream = await client.openStream()
    check not clientStream.isUnidirectional

    # Activate stream
    await clientStream.write(@[])
    let serverStream = await server.incomingStream()

    # Client sends data and fully closes stream
    let clientData = @[1'u8, 2, 3, 4, 5]
    await clientStream.write(clientData)
    await clientStream.close() # Full close

    # After close() client should NOT be able to write or read
    expect QuicError:
      await clientStream.write(@[6'u8, 7, 8])

    # Server should receive data and EOF
    let receivedData = await serverStream.read()
    check receivedData == clientData

    let eof = await serverStream.read()
    check eof.len == 0 # EOF

    # Server can still write back (until it receives indication that client closed read)
    # But in QUIC when close() is called, it closes ALL directions
    # TODO: this depends on specific RFC 9000 implementation

    await simulation.cancelAndWait()

  asyncTest "bidirectional closeWrite() - both sides close write independently":
    ## Test RFC 9000 bidirectional half-close semantics
    let simulation = simulateNetwork(client, server)

    let clientStream = await client.openStream()
    await clientStream.write(@[])
    let serverStream = await server.incomingStream()

    # Both send data
    let clientData = @[1'u8, 2, 3]
    let serverData = @[4'u8, 5, 6]

    await clientStream.write(clientData)
    await serverStream.write(serverData)

    # Both close their write side
    await clientStream.closeWrite()
    await serverStream.closeWrite()

    # Neither can write
    expect QuicError:
      await clientStream.write(@[7'u8])
    expect QuicError:
      await serverStream.write(@[8'u8])

    # But both can read each other's data
    let receivedByClient = await clientStream.read()
    let receivedByServer = await serverStream.read()

    check receivedByClient == serverData
    check receivedByServer == clientData

    # And both receive EOF
    let eofClient = await clientStream.read()
    let eofServer = await serverStream.read()

    check eofClient.len == 0
    check eofServer.len == 0

    await simulation.cancelAndWait()

  asyncTest "close() after closeWrite() should work correctly":
    ## After closeWrite() calling close() should also close the read side
    let simulation = simulateNetwork(client, server)

    let clientStream = await client.openStream()
    await clientStream.write(@[])
    let serverStream = await server.incomingStream()

    let clientData = @[1'u8, 2, 3]
    await clientStream.write(clientData)
    await clientStream.closeWrite() # First half-close

    # Server sends response
    let serverData = @[4'u8, 5, 6]
    await serverStream.write(serverData)

    # Client reads response
    let response = await clientStream.read()
    check response == serverData

    # Now client fully closes stream
    await clientStream.close()

    await simulation.cancelAndWait()

  asyncTest "mixed close() and closeWrite() semantics":
    ## One uses close(), other uses closeWrite()
    let simulation = simulateNetwork(client, server)

    let clientStream = await client.openStream()
    await clientStream.write(@[])
    let serverStream = await server.incomingStream()

    let clientData = @[1'u8, 2, 3]
    let serverData = @[4'u8, 5, 6]

    await clientStream.write(clientData)
    await serverStream.write(serverData)

    # Client does half-close
    await clientStream.closeWrite()

    # Server does full close
    await serverStream.close()

    # Client should receive data from server
    let receivedByClient = await clientStream.read()
    check receivedByClient == serverData

    # And EOF
    let eofClient = await clientStream.read()
    check eofClient.len == 0

    # Server should also receive data from client (before its close())
    let receivedByServer = await serverStream.read()
    check receivedByServer == clientData

    await simulation.cancelAndWait()

  asyncTest "stream state tracking for bidirectional closure":
    ## Check that stream state is properly tracked
    let simulation = simulateNetwork(client, server)

    let clientStream = await client.openStream()
    await clientStream.write(@[])
    let serverStream = await server.incomingStream()

    # Initially both streams are open
    check not clientStream.isClosed()
    check not serverStream.isClosed()

    # After closeWrite() stream should not be considered fully closed
    await clientStream.closeWrite()
    check not clientStream.isClosed() # Half-close ≠ closed

    # After peer also closes its side, stream may be considered closed
    await serverStream.closeWrite()

    # Read all data to reach final state
    discard await clientStream.read() # May be empty or EOF
    discard await serverStream.read() # May be empty or EOF

    # Now both streams should be closed

    await simulation.cancelAndWait()

  # Large data transfer tests
  asyncTest "simple 10MB write test":
    let simulation = simulateNetwork(client, server)
    let dataSize = 10 * 1024 * 1024 # 10 MB
    var testData = newSeq[uint8](dataSize)

    # Fill with pattern
    for i in 0 ..< dataSize:
      testData[i] = uint8(i mod 256)

    let clientStream = await client.openStream()
    let serverStreamFuture = server.incomingStream()

    # Activate stream
    await clientStream.write(@[])

    let serverStream = await serverStreamFuture

    # Server starts reading IMMEDIATELY (parallel with client writing)
    proc serverReadData(): Future[seq[uint8]] {.async.} =
      var receivedData: seq[uint8]
      var chunkCount = 0
      while true:
        let chunk = await serverStream.read()
        if chunk.len == 0:
          break
        receivedData.add(chunk)
        chunkCount += 1
      return receivedData

    let serverTask = serverReadData()

    # Client writes data WHILE server is reading
    await clientStream.write(testData)

    await clientStream.closeWrite()

    # Wait for server to finish reading
    let receivedData = await serverTask

    check receivedData.len == dataSize

    await serverStream.close()
    await clientStream.close()
    await simulation.cancelAndWait()

  asyncTest "bidirectional 10MB + 10MB closeWrite test":
    let simulation = simulateNetwork(client, server)
    let dataSize = 10 * 1024 * 1024 # 10 MB each direction

    # Client data pattern
    var clientData = newSeq[uint8](dataSize)
    for i in 0 ..< dataSize:
      clientData[i] = uint8(0xAA) # Client pattern

    # Server data pattern  
    var serverData = newSeq[uint8](dataSize)
    for i in 0 ..< dataSize:
      serverData[i] = uint8(0xBB) # Server pattern

    let clientStream = await client.openStream()
    let serverStreamFuture = server.incomingStream()

    # Activate stream
    await clientStream.write(@[])

    let serverStream = await serverStreamFuture

    # Start parallel read operations for both directions
    proc clientReadData(): Future[seq[uint8]] {.async.} =
      var receivedData: seq[uint8]
      var chunkCount = 0
      while true:
        let chunk = await clientStream.read()
        if chunk.len == 0:
          break
        receivedData.add(chunk)
        chunkCount += 1
      return receivedData

    proc serverReadData(): Future[seq[uint8]] {.async.} =
      var receivedData: seq[uint8]
      var chunkCount = 0
      while true:
        let chunk = await serverStream.read()
        if chunk.len == 0:
          break
        receivedData.add(chunk)
        chunkCount += 1
      return receivedData

    # Start both read tasks
    let clientReadTask = clientReadData()
    let serverReadTask = serverReadData()

    # Client writes 10MB and closes write side
    await clientStream.write(clientData)
    await clientStream.closeWrite()

    # Server writes 10MB and closes write side  
    await serverStream.write(serverData)
    await serverStream.closeWrite()

    # Wait for both read operations to complete
    let clientReceivedData = await clientReadTask
    let serverReceivedData = await serverReadTask

    # Verify data sizes
    check clientReceivedData.len == dataSize
    check serverReceivedData.len == dataSize

    # Verify data patterns
    var clientDataValid = true
    var serverDataValid = true

    for i in 0 ..< min(dataSize, clientReceivedData.len):
      if clientReceivedData[i] != 0xBB: # Client should receive server pattern
        clientDataValid = false
        break

    for i in 0 ..< min(dataSize, serverReceivedData.len):
      if serverReceivedData[i] != 0xAA: # Server should receive client pattern  
        serverDataValid = false
        break

    check clientDataValid
    check serverDataValid

    # Both sides should be able to detect EOF now
    let clientEOF = await clientStream.read()
    let serverEOF = await serverStream.read()
    check clientEOF.len == 0
    check serverEOF.len == 0

    await serverStream.close()
    await clientStream.close()
    await simulation.cancelAndWait()

  asyncTest "mixed semantics: client closeWrite + server close with 10MB":
    let simulation = simulateNetwork(client, server)
    let dataSize = 10 * 1024 * 1024 # 10 MB

    # Client data pattern
    var clientData = newSeq[uint8](dataSize)
    for i in 0 ..< dataSize:
      clientData[i] = uint8(0xCC) # Client pattern

    # Server data pattern  
    var serverData = newSeq[uint8](dataSize)
    for i in 0 ..< dataSize:
      serverData[i] = uint8(0xDD) # Server pattern

    let clientStream = await client.openStream()
    let serverStreamFuture = server.incomingStream()

    # Activate stream
    await clientStream.write(@[])

    let serverStream = await serverStreamFuture

    # Start parallel read operations
    proc clientReadData(): Future[seq[uint8]] {.async.} =
      var receivedData: seq[uint8]
      var chunkCount = 0
      while true:
        let chunk = await clientStream.read()
        if chunk.len == 0:
          break
        receivedData.add(chunk)
        chunkCount += 1
      return receivedData

    proc serverReadData(): Future[seq[uint8]] {.async.} =
      var receivedData: seq[uint8]
      var chunkCount = 0
      while true:
        let chunk = await serverStream.read()
        if chunk.len == 0:
          break
        receivedData.add(chunk)
        chunkCount += 1
      return receivedData

    # Start both read tasks
    let clientReadTask = clientReadData()
    let serverReadTask = serverReadData()

    # Client writes 10MB and does closeWrite() (half-close)
    await clientStream.write(clientData)
    await clientStream.closeWrite()

    # Server writes 10MB and does close() (full-close)  
    await serverStream.write(serverData)
    await serverStream.close()

    # Wait for both read operations to complete
    let clientReceivedData = await clientReadTask
    let serverReceivedData = await serverReadTask

    # Verify data sizes
    check clientReceivedData.len == dataSize
    check serverReceivedData.len == dataSize

    # Verify data patterns
    var clientDataValid = true
    var serverDataValid = true

    for i in 0 ..< min(dataSize, clientReceivedData.len):
      if clientReceivedData[i] != 0xDD: # Client should receive server pattern
        clientDataValid = false
        break

    for i in 0 ..< min(dataSize, serverReceivedData.len):
      if serverReceivedData[i] != 0xCC: # Server should receive client pattern  
        serverDataValid = false
        break

    check clientDataValid
    check serverDataValid

    # Client should get EOF when trying to read (server did full close)
    let clientEOF = await clientStream.read()
    check clientEOF.len == 0

    # Client should still be able to close its read side
    await clientStream.close()

    await simulation.cancelAndWait()

  asyncTest "reverse order: client starts writing first, server reads parallel":
    let simulation = simulateNetwork(client, server)
    let dataSize = 10 * 1024 * 1024 # 10 MB

    var testData = newSeq[uint8](dataSize)
    for i in 0 ..< dataSize:
      testData[i] = uint8(0xEE) # Pattern for this test

    let clientStream = await client.openStream()
    let serverStreamFuture = server.incomingStream()

    # Activate stream
    await clientStream.write(@[])

    let serverStream = await serverStreamFuture

    # CLIENT STARTS WRITING FIRST (non-blocking)
    let clientWriteTask = proc() {.async.} =
      await clientStream.write(testData)
      await clientStream.closeWrite()

    let clientTask = clientWriteTask()

    # Small delay to let client start writing first
    await sleepAsync(5.milliseconds)

    # SERVER STARTS READING IN PARALLEL (after client already started)
    proc serverReadData(): Future[seq[uint8]] {.async.} =
      var receivedData: seq[uint8]
      var chunkCount = 0
      while true:
        let chunk = await serverStream.read()
        if chunk.len == 0:
          break
        receivedData.add(chunk)
        chunkCount += 1
      return receivedData

    let serverTask = serverReadData()

    # Wait for both operations to complete
    await clientTask
    let receivedData = await serverTask

    # Verify data
    check receivedData.len == dataSize

    # Verify data pattern
    var dataValid = true
    for i in 0 ..< min(dataSize, receivedData.len):
      if receivedData[i] != 0xEE:
        dataValid = false
        break

    check dataValid

    # EOF check
    let eofCheck = await serverStream.read()
    check eofCheck.len == 0

    await serverStream.close()
    await clientStream.close()
    await simulation.cancelAndWait()
