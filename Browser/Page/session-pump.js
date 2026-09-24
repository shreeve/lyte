// The session pump: WebTransport datagrams ↔ the WASM session. It owns the
// carrier and the clock and applies every step the same way — notes, newly
// scheduled frames, status, outbound datagrams — whichever call produced it.

import {
  DatagramReader,
  nowMicros,
  openWebTransport,
  packDatagrams,
  unpackDatagrams,
} from "./lyte-io.js";

// Session notes kept for the page log; older ones fall off.
const MAX_NOTES = 2_000;

export class SessionPump {
  static async open(bridge, sidecar, { hostStaticPublicKeyHex, pin }) {
    const opened = bridge.controlOpen(hostStaticPublicKeyHex, pin);
    if (!opened?.ok) throw new Error(`controlOpen: ${opened?.error || "?"}`);
    const wt = await openWebTransport(sidecar);
    return new SessionPump(bridge, wt, opened.clientStaticPublicKeyHex);
  }

  constructor(bridge, wt, clientStaticPublicKeyHex) {
    this.bridge = bridge;
    this.wt = wt;
    this.clientStaticPublicKeyHex = clientStaticPublicKeyHex;
    this.writer = wt.datagrams.writable.getWriter();
    this.reader = new DatagramReader(wt.datagrams.readable);
    this.outbound = [];
    this.notes = [];
    this.status = "idle";
    this.failure = null;
    this.ingested = 0;
    this.batches = 0;
    this.onScheduled = null;
  }

  get ready() {
    return this.status === "ready";
  }

  get failed() {
    return this.status === "failed";
  }

  get closed() {
    return this.status === "closed";
  }

  /** Applies one WASM step (`null` means nothing to act on). */
  apply(step) {
    if (!step) return null;
    if (step.events) {
      for (const line of step.events.split("\n")) this.notes.push(line);
      if (this.notes.length > MAX_NOTES) this.notes.splice(0, this.notes.length - MAX_NOTES);
    }
    if (step.scheduled?.length && this.onScheduled) this.onScheduled(step.scheduled);
    if (step.outbound) this.outbound.push(step.outbound);
    this.status = step.status;
    if (step.failed) this.failure = step.detail;
    return step;
  }

  /** Applies a step and sends its datagrams now. */
  async send(step) {
    this.apply(step);
    await this.flush();
    return step;
  }

  async flush() {
    const batches = this.outbound;
    this.outbound = [];
    for (const packed of batches) {
      for (const datagram of unpackDatagrams(packed)) {
        try {
          await this.writer.write(datagram);
        } catch (error) {
          this.failure = this.failure || `carrier write: ${error?.message || error}`;
          return;
        }
      }
    }
  }

  begin() {
    return this.send(this.bridge.controlBegin(nowMicros()));
  }

  /** Ingests everything the reader has queued as one batch. */
  drain() {
    const batch = this.reader.take();
    if (batch.length) {
      this.ingested += batch.length;
      this.batches += 1;
      this.apply(this.bridge.controlIngestBatch(packDatagrams(batch), nowMicros()));
    }
    if (this.reader.done && !this.failed && !this.closed) {
      this.status = "failed";
      this.failure = this.failure || `carrier closed: ${this.reader.error?.message || "EOF"}`;
    }
    return batch.length;
  }

  tick() {
    return this.apply(this.bridge.controlTick(nowMicros()));
  }

  /** One pump turn: ingest, tick, send. Waits up to `waitMs` for input. */
  async turn(waitMs = 0) {
    if (waitMs > 0) await this.reader.wait(waitMs);
    const ingested = this.drain();
    this.tick();
    await this.flush();
    return ingested;
  }

  facts() {
    return this.bridge.controlFacts();
  }

  async close(reason = "done") {
    await this.reader.cancel();
    try {
      await this.writer.close();
    } catch {
      /* carrier already gone */
    }
    try {
      this.wt.close({ closeCode: 0, reason });
    } catch {
      /* already closed */
    }
  }
}
