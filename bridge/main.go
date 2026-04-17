// Doom-on-Redpanda WebSocket bridge.
//
// One tab per player. Inbound WS frames are produced to the input
// topic; records consumed from the frames topic are pushed to the WS.
// Also serves the static index.html + doom.js.
//
// With produce-path transforms enabled, input-topic == frames-topic.

package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"embed"
	"errors"
	"flag"
	"io/fs"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/twmb/franz-go/pkg/kgo"
	"nhooyr.io/websocket"
)

//go:embed web
var webFS embed.FS

// dumpWriter appends one JSONL record per sampled event to a file.
// All methods are safe for concurrent use.
type dumpWriter struct {
	mu   sync.Mutex
	f    *os.File
	path string
	// Atomic counter of every record seen (not just sampled).
	total uint64
}

func newDumpWriter(path string) (*dumpWriter, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return nil, err
	}
	return &dumpWriter{f: f, path: path}, nil
}

func (d *dumpWriter) Close() {
	if d == nil {
		return
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	_ = d.f.Close()
}

// observe records that a new event occurred. Every `every`th call
// writes the payload bytes to the underlying file as one JSONL line.
func (d *dumpWriter) observe(direction string, every uint64, payload []byte) {
	if d == nil {
		return
	}
	d.mu.Lock()
	d.total++
	n := d.total
	d.mu.Unlock()
	if every == 0 || n%every != 0 {
		return
	}
	entry := struct {
		Ts        string `json:"ts"`
		Direction string `json:"dir"`
		Seq       uint64 `json:"seq"`
		Size      int    `json:"size"`
		B64       string `json:"b64"`
	}{
		Ts:        time.Now().UTC().Format(time.RFC3339Nano),
		Direction: direction,
		Seq:       n,
		Size:      len(payload),
		B64:       base64.StdEncoding.EncodeToString(payload),
	}
	b, err := json.Marshal(entry)
	if err != nil {
		return
	}
	b = append(b, '\n')
	d.mu.Lock()
	_, _ = d.f.Write(b)
	d.mu.Unlock()
}

func main() {
	brokers := flag.String("brokers", env("BRIDGE_BROKERS", "localhost:9092"),
		"comma-separated Kafka broker list")
	inputTopic := flag.String("input-topic", env("BRIDGE_INPUT_TOPIC", "doom"),
		"input topic name")
	framesTopic := flag.String("frames-topic", env("BRIDGE_FRAMES_TOPIC", "doom"),
		"frames topic name")
	listen := flag.String("listen", env("BRIDGE_LISTEN", ":8080"),
		"HTTP listen address")
	dumpDir := flag.String("dump-dir", env("BRIDGE_DUMP_DIR", ""),
		"if non-empty, write JSONL dumps of sampled records here")
	sampleEvery := flag.Uint64("sample-every", envU64("BRIDGE_SAMPLE_EVERY", 10),
		"write every Nth record seen per direction")
	flag.Parse()

	ctx, cancel := signal.NotifyContext(context.Background(),
		os.Interrupt, syscall.SIGTERM)
	defer cancel()

	var inDump, outDump *dumpWriter
	if *dumpDir != "" {
		var err error
		inDump, err = newDumpWriter(filepath.Join(*dumpDir, "in.jsonl"))
		if err != nil {
			log.Printf("dump: disabled — can't write to %s (%v)", *dumpDir, err)
			log.Printf("dump: hint: chmod 777 the host-side dump dir")
			inDump, outDump = nil, nil
		} else {
			defer inDump.Close()
			outDump, err = newDumpWriter(filepath.Join(*dumpDir, "out.jsonl"))
			if err != nil {
				log.Printf("dump: frames-side disabled — %v", err)
				outDump = nil
			} else {
				defer outDump.Close()
			}
			log.Printf("dump: writing every %dth record to %s/{in,out}.jsonl",
				*sampleEvery, *dumpDir)
		}
	}

	webRoot, err := fs.Sub(webFS, "web")
	if err != nil {
		log.Fatalf("embed fs: %v", err)
	}

	mux := http.NewServeMux()
	mux.Handle("/", http.FileServer(http.FS(webRoot)))
	mux.HandleFunc("/ws", func(w http.ResponseWriter, r *http.Request) {
		handleWS(r.Context(), w, r, *brokers, *inputTopic, *framesTopic,
			inDump, outDump, *sampleEvery)
	})

	srv := &http.Server{Addr: *listen, Handler: mux}
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdown)
	}()

	log.Printf("bridge: listen=%s brokers=%s input=%s frames=%s",
		*listen, *brokers, *inputTopic, *framesTopic)
	if err := srv.ListenAndServe(); !errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("http server: %v", err)
	}
}

func handleWS(ctx context.Context, w http.ResponseWriter, r *http.Request,
	brokers, inputTopic, framesTopic string,
	inDump, outDump *dumpWriter, sampleEvery uint64) {

	c, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		InsecureSkipVerify: true, // demo: trust local origin
	})
	if err != nil {
		log.Printf("ws accept: %v", err)
		return
	}
	defer c.Close(websocket.StatusInternalError, "closing")

	log.Printf("ws: client connected from %s", r.RemoteAddr)

	// Per-session producer + consumer. AtEnd for the consumer so a
	// new tab gets a fresh stream, not a backlog of old frames.
	producer, err := kgo.NewClient(
		kgo.SeedBrokers(strings.Split(brokers, ",")...),
		kgo.DefaultProduceTopic(inputTopic),
		kgo.ProducerLinger(0),
		kgo.RequiredAcks(kgo.LeaderAck()),
		kgo.DisableIdempotentWrite(),
		kgo.ProducerBatchCompression(kgo.NoCompression()),
	)
	if err != nil {
		log.Printf("producer: %v", err)
		return
	}
	defer producer.Close()

	consumer, err := kgo.NewClient(
		kgo.SeedBrokers(strings.Split(brokers, ",")...),
		kgo.ConsumeTopics(framesTopic),
		kgo.ConsumeResetOffset(kgo.NewOffset().AtEnd()),
	)
	if err != nil {
		log.Printf("consumer: %v", err)
		return
	}
	defer consumer.Close()

	// Pump frames → WS.
	errc := make(chan error, 2)
	go func() {
		for {
			fetches := consumer.PollFetches(ctx)
			if errs := fetches.Errors(); len(errs) > 0 {
				errc <- errs[0].Err
				return
			}
			fetches.EachRecord(func(rec *kgo.Record) {
				outDump.observe("frame", sampleEvery, rec.Value)
				wctx, cancel := context.WithTimeout(ctx, 2*time.Second)
				err := c.Write(wctx, websocket.MessageBinary, rec.Value)
				cancel()
				if err != nil {
					errc <- err
					return
				}
			})
		}
	}()

	// Pump WS → input topic.
	go func() {
		for {
			msgType, data, err := c.Read(ctx)
			if err != nil {
				errc <- err
				return
			}
			if msgType != websocket.MessageBinary {
				continue
			}
			inDump.observe("input", sampleEvery, data)
			producer.Produce(ctx, &kgo.Record{
				Topic: inputTopic,
				Key:   []byte("p1"),
				Value: data,
			}, func(r *kgo.Record, pErr error) {
				if pErr != nil {
					log.Printf("produce err: %v", pErr)
				}
			})
		}
	}()

	select {
	case err := <-errc:
		log.Printf("ws: client disconnected: %v", err)
	case <-ctx.Done():
	}
	c.Close(websocket.StatusNormalClosure, "")
}

func env(key, fallback string) string {
	if v, ok := os.LookupEnv(key); ok {
		return v
	}
	return fallback
}

func envU64(key string, fallback uint64) uint64 {
	if v, ok := os.LookupEnv(key); ok {
		if n, err := strconv.ParseUint(v, 10, 64); err == nil {
			return n
		}
	}
	return fallback
}
