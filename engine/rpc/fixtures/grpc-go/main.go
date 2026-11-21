// Exercise the Flint listener with gRPC-Go's standard Protobuf codec.
package main

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	"sync"
	"sync/atomic"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protodesc"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/types/descriptorpb"
	"google.golang.org/protobuf/types/dynamicpb"
)

const method = "/flint.rpc.fixture.Echo/"

type client struct {
	connection *grpc.ClientConn
	descriptor protoreflect.MessageDescriptor
}

func main() {
	if len(os.Args) != 3 && (len(os.Args) != 4 || os.Args[3] != "--bench") {
		panic("usage: grpc-go-loopback HOST:PORT DESCRIPTOR [--bench]")
	}
	encoded, err := os.ReadFile(os.Args[2])
	require(err)
	var descriptorSet descriptorpb.FileDescriptorSet
	require(proto.Unmarshal(encoded, &descriptorSet))
	files, err := protodesc.NewFiles(&descriptorSet)
	require(err)
	descriptor, err := files.FindDescriptorByName("flint.rpc.fixture.Envelope")
	require(err)
	target := "passthrough:///" + os.Args[1]
	connection, err := grpc.NewClient(target,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithDefaultCallOptions(grpc.WaitForReady(true)))
	require(err)
	defer connection.Close()
	peer := client{connection, descriptor.(protoreflect.MessageDescriptor)}
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	if len(os.Args) == 4 {
		peer.benchmark(ctx)
		return
	}
	peer.unary(ctx, []byte("hello grpc-go"))
	peer.clientStream(ctx)
	peer.serverStream(ctx)
	peer.bidi(ctx)
	peer.lifecycle(ctx)
	fmt.Println("grpc-go standard Protobuf codec, four RPC shapes, metadata, deadline and cancellation passed")
}

func require(err error) {
	if err != nil {
		panic(err)
	}
}

func (c client) payload(bytes []byte) *dynamicpb.Message {
	message := dynamicpb.NewMessage(c.descriptor)
	if len(bytes) != 0 {
		message.Set(c.descriptor.Fields().ByName("payload"), protoreflect.ValueOfBytes(bytes))
	}
	return message
}

func (c client) check(message *dynamicpb.Message, expected []byte) {
	actual := message.Get(c.descriptor.Fields().ByName("payload")).Bytes()
	if !bytes.Equal(actual, expected) {
		panic(fmt.Errorf("expected %d payload bytes, got %d", len(expected), len(actual)))
	}
}

func (c client) unary(ctx context.Context, expected []byte) {
	ctx = metadata.AppendToOutgoingContext(ctx, "x-flint-check", "grpc-go")
	var header metadata.MD
	response := c.payload(nil)
	require(c.connection.Invoke(ctx, method+"Unary", c.payload(expected), response, grpc.Header(&header)))
	c.check(response, expected)
}

func (c client) clientStream(ctx context.Context) {
	stream, err := c.connection.NewStream(ctx, &grpc.StreamDesc{ClientStreams: true}, method+"ClientStream")
	require(err)
	for _, value := range []string{"one", "two", "three"} {
		require(stream.SendMsg(c.payload([]byte(value))))
	}
	require(stream.CloseSend())
	output := c.payload(nil)
	require(stream.RecvMsg(output))
	c.check(output, []byte("three"))
}

func (c client) serverStream(ctx context.Context) {
	stream, err := c.connection.NewStream(ctx, &grpc.StreamDesc{ServerStreams: true}, method+"ServerStream")
	require(err)
	require(stream.SendMsg(c.payload([]byte("repeat"))))
	require(stream.CloseSend())
	for index := 0; index < 3; index++ {
		output := c.payload(nil)
		require(stream.RecvMsg(output))
		c.check(output, []byte("repeat"))
	}
	if err := stream.RecvMsg(c.payload(nil)); err != io.EOF {
		panic(fmt.Errorf("server stream did not terminate: %w", err))
	}
}

func (c client) bidi(ctx context.Context) {
	stream, err := c.connection.NewStream(ctx, &grpc.StreamDesc{ClientStreams: true, ServerStreams: true}, method+"Bidi")
	require(err)
	payloads := [][]byte{bytes.Repeat([]byte("a"), 65_536), bytes.Repeat([]byte("b"), 65_536)}
	errors := make(chan error, 1)
	var writer sync.WaitGroup
	writer.Add(1)
	go func() {
		defer writer.Done()
		for _, payload := range payloads {
			if err := stream.SendMsg(c.payload(payload)); err != nil {
				errors <- err
				return
			}
		}
		errors <- stream.CloseSend()
	}()
	for _, payload := range payloads {
		output := c.payload(nil)
		require(stream.RecvMsg(output))
		c.check(output, payload)
	}
	writer.Wait()
	require(<-errors)
	if err := stream.RecvMsg(c.payload(nil)); err != io.EOF {
		panic(fmt.Errorf("duplex call did not terminate: %w", err))
	}
}

func (c client) lifecycle(ctx context.Context) {
	timed, deadline := context.WithTimeout(ctx, 40*time.Millisecond)
	defer deadline()
	stream, err := c.connection.NewStream(timed, &grpc.StreamDesc{ClientStreams: true}, method+"ClientStream")
	require(err)
	if err := stream.RecvMsg(c.payload(nil)); status.Code(err) != codes.DeadlineExceeded {
		panic(fmt.Errorf("expected deadline, got %w", err))
	}

	cancelled, cancel := context.WithCancel(ctx)
	stream, err = c.connection.NewStream(cancelled, &grpc.StreamDesc{ClientStreams: true}, method+"ClientStream")
	require(err)
	cancel()
	if err := stream.RecvMsg(c.payload(nil)); status.Code(err) != codes.Canceled {
		panic(fmt.Errorf("expected cancellation, got %w", err))
	}
	c.unary(ctx, []byte("same connection remains usable"))
}

func (c client) benchmark(ctx context.Context) {
	for _, size := range []int{128, 65_536} {
		for _, streams := range []int{1, 64} {
			payload := bytes.Repeat([]byte{17}, size)
			started := time.Now()
			finish := started.Add(150 * time.Millisecond)
			var calls atomic.Uint64
			var workers sync.WaitGroup
			for worker := 0; worker < streams; worker++ {
				workers.Add(1)
				go func() {
					defer workers.Done()
					for {
						if size == 128 {
							c.unary(ctx, payload)
						} else {
							c.oneStream(ctx, payload)
						}
						calls.Add(1)
						if time.Now().After(finish) {
							return
						}
					}
				}()
			}
			workers.Wait()
			fmt.Printf("payload_bytes=%d concurrent_calls=%d calls=%d elapsed_ns=%d\n",
				size, streams, calls.Load(), time.Since(started).Nanoseconds())
		}
	}
}

func (c client) oneStream(ctx context.Context, payload []byte) {
	stream, err := c.connection.NewStream(ctx, &grpc.StreamDesc{ClientStreams: true, ServerStreams: true}, method+"Bidi")
	require(err)
	require(stream.SendMsg(c.payload(payload)))
	require(stream.CloseSend())
	output := c.payload(nil)
	require(stream.RecvMsg(output))
	c.check(output, payload)
	if err := stream.RecvMsg(c.payload(nil)); err != io.EOF {
		panic(fmt.Errorf("benchmark duplex call did not terminate: %w", err))
	}
}
