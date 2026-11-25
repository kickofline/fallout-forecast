#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["websockets==15.0.1"]
# ///
"""Conformance checks for the Open Protocol Thin tier."""

import argparse
from contextlib import asynccontextmanager
import asyncio
import json
import math
import os
import struct
import statistics
import time

from websockets.asyncio.client import connect
from websockets.exceptions import ConnectionClosedError, ConnectionClosedOK

FIRE = 1
AIM = 2
READY_UP = 1024



STATES = ("ok", "downed", "turned", "out")
TYPES = ("drip", "gutter", "mister", "hailstone", "sleet", "smog", "static",
         "thunderhead", "undertow", "cloudburst", "cumulus", "turned")
ANIMS = ("spawn", "idle", "walk", "attack", "windup", "stagger", "die")
KINDS = ("weapon", "ammo", "health", "suit", "scrap", "item", "airdrop", "station")
PHASES = ("calm", "drizzle", "downpour", "acid_storm", "clearing")


class BinaryReader:
    def __init__(self, raw):
        self.raw = raw
        self.offset = 0

    def read(self, fmt):
        fmt = "<" + fmt
        values = struct.unpack_from(fmt, self.raw, self.offset)
        self.offset += struct.calcsize(fmt)
        return values if len(values) > 1 else values[0]

    def text(self):
        length = self.read("H")
        end = self.offset + length
        assert end <= len(self.raw), "Truncated string"
        value = self.raw[self.offset:end].decode()
        self.offset = end
        return value

    def scaled(self, scale):
        value = self.read("H")
        return value / scale if value != 65535 else None

    def position(self):
        return [part / 100 for part in self.read("iii")]

    def velocity(self):
        return [part / 100 for part in self.read("hhh")]

    def angle(self):
        return self.read("h") / 1000

    def enum(self, names):
        index = self.read("B")
        return None if index == 255 else names[index]


def binary_snapshot(payload):
    r = BinaryReader(payload)
    tag, tick, t_ms, ack = r.read("BIQI")
    assert tag == 2, f"Unexpected binary tag {tag}"
    you = {"id": r.read("I"), "pos": r.position(), "vel": r.velocity(),
           "yaw": r.angle(), "pitch": r.angle(), "state": r.enum(STATES)}
    for field in ("hp", "hp_max", "suit", "suit_max"):
        you[field] = r.scaled(100)
    flags, you["slot"] = r.read("BB")
    for bit, field in enumerate(("exposed", "sheltered", "in_puddle",
                                 "crouch", "aiming", "reloading")):
        you[field] = bool(flags & (1 << bit))
    you["slots"] = []
    for _ in range(5):
        slot = None
        if r.read("B"):
            slot = {"item": r.text(), "name": r.text()}
            for field in ("ammo", "mag", "reserve", "count"):
                value = r.read("H")
                slot[field] = value if value != 65535 else None
        you["slots"].append(slot)
    you.update(scrap=r.read("I"), revive=r.scaled(1000), interact_progress=r.scaled(1000),
               prompt=r.text(), pouch=r.text(), grenades=r.read("H"), domes=r.read("H"))
    players = []
    for _ in range(r.read("H")):
        row = {"id": r.read("I"), "pos": r.position(), "yaw": r.angle(),
               "pitch": r.angle(), "state": r.enum(STATES)}
        crouch = r.read("B")
        row.update(crouch=None if crouch == 2 else bool(crouch), name=r.text(), item=r.text(),
                   suit_color=f"#{r.read('I') >> 8:06x}", skin=r.text())
        players.append(row)
    enemies = []
    for _ in range(r.read("H")):
        enemies.append({"id": r.read("i"), "type": r.enum(TYPES), "pos": r.position(),
                        "yaw": r.angle(), "hp": r.scaled(1000), "anim": r.enum(ANIMS)})
    pickups = []
    for _ in range(r.read("H")):
        pickups.append({"id": r.read("q"), "kind": r.enum(KINDS), "pos": r.position(),
                        "item": r.text()})
    projectiles = []
    for _ in range(r.read("H")):
        projectiles.append({"id": r.read("q"), "pos": r.position(),
                            "vel": r.velocity(), "kind": r.text()})
    weather = {"phase": r.enum(PHASES), "intensity": r.scaled(1000), "wave": r.read("I"),
               "phase_time_left": r.read("I") / 100, "lightning": bool(r.read("B"))}
    run = {"alive_enemies": r.read("H"), "wave": weather["wave"], "endless": bool(r.read("B")),
           "shared_decon": r.read("H"), "score": r.read("I")}
    assert r.offset == len(payload), "Trailing bytes in snapshot"
    return {"t": "snap", "tick": tick, "t_ms": t_ms, "ack": -1 if ack == 0xFFFFFFFF else ack,
            "you": you, "players": players, "enemies": enemies, "pickups": pickups,
            "projectiles": projectiles, "weather": weather, "run": run}


class RawSocket:
    def __init__(self, reader, writer):
        self.reader = reader
        self.writer = writer

    async def send(self, payload):
        if isinstance(payload, str):
            payload = payload.encode()
        self.writer.write(struct.pack("<I", len(payload)) + payload)
        await self.writer.drain()

    async def recv(self):
        length, = struct.unpack("<I", await self.reader.readexactly(4))
        assert 0 < length <= 524288, f"Invalid raw length {length}"
        payload = await self.reader.readexactly(length)
        return payload if payload[0] < 9 else payload.decode()


@asynccontextmanager
async def open_socket(args):
    if args.transport == "tcp":
        reader, writer = await asyncio.wait_for(asyncio.open_connection(args.host, args.port or 7781), 5)
        try:
            yield RawSocket(reader, writer)
        finally:
            writer.close()
            await writer.wait_closed()
    else:
        url = args.url or f"ws://{args.host}:{args.port or 7780}/"
        async with connect(url, compression=None, open_timeout=10, close_timeout=2) as socket:
            yield socket


class Client:
    def __init__(self, socket, args):
        self.socket = socket
        self.args = args
        self.encoding = args.enc
        self.first_snap = None
        self.last_snap = None
        self.snapshots = 0
        self.sequence = 0
        self.move = [0, 0]
        self.yaw = 0
        self.pitch = 0
        self.buttons = 0
        self.latest = None
        self.saw_hurt = False
        self.next_read = 0.0
        self.sizes = {"without_enemies": [], "with_enemies": []}

    async def send(self, kind, **fields):
        await self.socket.send(json.dumps({"t": kind, **fields}, separators=(",", ":")))

    async def wait(self, kind, predicate=lambda _: True, timeout=15):
        async with asyncio.timeout(timeout):
            while True:
                if self.args.read_rate:
                    now = time.monotonic()
                    await asyncio.sleep(max(0, self.next_read - now))
                    self.next_read = time.monotonic() + 1 / self.args.read_rate
                payload = await self.socket.recv()
                if isinstance(payload, bytes):
                    assert self.encoding == "bin", "Unexpected binary frame"
                    message = binary_snapshot(payload)
                else:
                    message = json.loads(payload)
                if message["t"] == "error" and kind != "error":
                    raise RuntimeError(message["msg"])
                if message["t"] == "ev":
                    self.saw_hurt |= any(event["e"] == "hurt" for event in message["list"])
                if message["t"] == "snap":
                    assert self.encoding != "bin" or isinstance(payload, bytes), "Expected binary snapshot"
                    self.check_snapshot(message)
                    self.latest = message
                    band = "with_enemies" if message["enemies"] else "without_enemies"
                    size = len(payload.encode()) if isinstance(payload, str) else len(payload)
                    self.sizes[band].append(size)
                if message["t"] == kind and predicate(message):
                    return message

    async def input_loop(self):
        loop = asyncio.get_running_loop()
        wake = loop.time()
        while True:
            self.sequence += 1
            if self.encoding == "bin":
                await self.socket.send(struct.pack("<BIhhhhHBb", 1, self.sequence,
                    round(self.move[0] * 32767), round(self.move[1] * 32767),
                    round(self.yaw * 1000), round(self.pitch * 1000), self.buttons, 0, 0))
            else:
                await self.send("in", seq=self.sequence, mv=self.move, yaw=self.yaw,
                                pitch=self.pitch, b=self.buttons, slot=0, wheel=0)
            wake = max(wake + 1 / 30, loop.time())
            await asyncio.sleep(wake - loop.time())

    def check_snapshot(self, frame):
        assert len(frame["you"]["slots"]) == 5
        assert 1 <= frame["you"]["slot"] <= 5
        assert frame["you"]["state"] in STATES and frame["weather"]["phase"] in PHASES
        assert frame["run"]["wave"] == frame["weather"]["wave"]
        if self.latest:
            assert frame["tick"] > self.latest["tick"]
            assert frame["t_ms"] >= self.latest["t_ms"]
            assert frame["ack"] >= self.latest["ack"]
        if self.first_snap is None:
            self.first_snap = frame["t_ms"]
        self.last_snap = frame["t_ms"]
        self.snapshots += 1
        if self.args.max_enemies is not None:
            assert len(frame["enemies"]) <= self.args.max_enemies
        if self.args.radius:
            for field in ("enemies", "pickups", "projectiles"):
                distances = [math.dist(row["pos"], frame["you"]["pos"]) for row in frame[field]]
                assert all(d <= self.args.radius + 0.03 for d in distances)
                assert all(a <= b + 0.03 for a, b in zip(distances, distances[1:]))

    async def play(self, you, map_id, observe_seconds):
        await self.send("lobby", a="chat", text="Open Protocol check")
        await self.wait("lobby", lambda m: any(c["text"] == "Open Protocol check" for c in m["chat"]))
        await self.send("lobby", a="vote", map=map_id)
        await self.wait("lobby", lambda m: any(p["id"] == you and p["vote"] == map_id for p in m["players"]))
        await self.send("lobby", a="ready", v=True)
        await self.wait("lobby", lambda m: any(p["id"] == you and p["ready"] for p in m["players"]))
        await self.send("lobby", a="start")
        load = await self.wait("load", timeout=30)
        if self.args.stall_after_load:
            print(f"Stalling all client I/O for {self.args.stall_after_load:g} s after load", flush=True)
            # A blocked game thread can't poll the socket or answer WebSocket pings.
            time.sleep(self.args.stall_after_load)
        if self.args.send_loaded:
            await self.send("loaded")
        await self.wait("status", lambda m: m["state"] == "run", timeout=30)
        print(f"PASS run ready on {load['map']}", flush=True)
        await self.send("map_req")
        outline = await self.wait("map")
        assert outline["id"] == load["map"] and outline["boxes"], outline
        assert len(outline["bounds"]["min"]) == len(outline["bounds"]["max"]) == 3
        assert all(len(box) == 7 and all(side > 0 for side in box[3:6]) for box in outline["boxes"])
        print(f"PASS map outline has {len(outline['boxes'])} boxes", flush=True)

        inputs = asyncio.create_task(self.input_loop())
        try:
            start = await self.wait("snap", lambda m: m["you"]["slots"][0] is not None)
            origin = start["you"]["pos"]
            ammo = start["you"]["slots"][0]["ammo"]
            self.move = [0, -0.65]
            moved = await self.wait(
                "snap", lambda m: m["ack"] > 0 and planar_distance(origin, m["you"]["pos"]) > 1.0,
            )
            self.move = [0, 0]
            self.yaw = 1.2
            self.pitch = -0.25
            turned = await self.wait("snap", lambda m: abs(m["you"]["yaw"] - 1.2) < 0.01
                                     and abs(m["you"]["pitch"] + 0.25) < 0.01)
            self.pitch = 2.5
            clamped = await self.wait("snap", lambda m: abs(m["you"]["pitch"] - math.radians(88)) < 0.01)
            self.pitch = -0.25
            print(f"Walked {planar_distance(origin, moved['you']['pos']):.2f} m, "
                  f"yaw {turned['you']['yaw']:.3f} rad, pitch clamp {clamped['you']['pitch']:.3f} rad", flush=True)

            self.buttons = AIM
            await self.wait("snap", lambda m: m["you"]["aiming"])
            self.buttons = AIM | FIRE
            await self.wait("ev", lambda m: any(e["e"] == "shot" and e["by"] == you for e in m["list"]))
            self.buttons = READY_UP
            fired = await self.wait("snap", lambda m: m["you"]["slots"][0]["ammo"] < ammo)
            print(f"Confirmed shot and ammo {ammo} -> {fired['you']['slots'][0]['ammo']}", flush=True)
            self.buttons = 0

            enemies = await self.wait("snap", lambda m: m["run"]["alive_enemies"] > 0, timeout=90)
            if not self.args.radius and self.args.max_enemies != 0:
                assert enemies["enemies"]
            print(f"PASS saw {enemies['run']['alive_enemies']} enemies on wave {enemies['run']['wave']}", flush=True)
            end = time.monotonic() + observe_seconds
            await self.wait("snap", lambda _: time.monotonic() >= end, timeout=observe_seconds + 10)
            if self.args.require_results:
                if not self.saw_hurt:
                    await self.wait("ev", lambda m: any(e["e"] == "hurt" for e in m["list"]), timeout=90)
                results = await self.wait("results", timeout=90)
                assert any(p["name"] == self.args.name for p in results["players"]), results
                print(f"PASS damage and result for {self.args.name}", flush=True)
        finally:
            inputs.cancel()
            await asyncio.gather(inputs, return_exceptions=True)

    def print_sizes(self):
        duration = (self.last_snap - self.first_snap) / 1000
        if duration > 3 and not self.args.read_rate:
            rate = (self.snapshots - 1) / duration
            assert abs(rate - self.args.rate) <= max(0.75, self.args.rate * 0.15), rate
            print(f"PASS snapshot cadence {rate:.2f} Hz")
        for band, sizes in self.sizes.items():
            if sizes:
                print(f"{band}: {len(sizes)} snapshots, payload bytes min/median/p95/max "
                      f"{min(sizes)}/{statistics.median(sizes):g}/"
                      f"{sorted(sizes)[math.ceil(0.95 * len(sizes)) - 1]}/{max(sizes)}")


def planar_distance(a, b):
    return math.hypot(a[0] - b[0], a[2] - b[2])


async def main(args):
    async with open_socket(args) as socket:
        car = Client(socket, args)
        hello = {"v": 1, "name": args.name, "client": "fake-client/1", "tier": args.tier,
                 "enc": args.enc, "rate": args.rate}
        for key in ("code", "radius", "max_enemies"):
            if getattr(args, key) is not None:
                hello[key] = getattr(args, key)
        await car.send("hello", **hello)
        if args.expect_error:
            error = await car.wait("error", timeout=5)
            assert args.expect_error in error["msg"], error
            await assert_closed(socket, rejected=True)
            print(f"PASS rejected handshake ({error['msg']})", flush=True)
            return
        welcome = await car.wait("welcome", timeout=15)
        assert welcome["v"] == 1 and welcome["tier"] == "thin" and welcome["enc"] == args.enc, welcome
        assert welcome["rate"] == args.rate, welcome
        you = welcome["you"]
        await car.wait("lobby", lambda m: any(p["id"] == you and p["car"] is True for p in m["players"]))
        now = int(time.monotonic() * 1000)
        await car.send("ping", ms=now)
        await car.wait("pong", lambda m: m["ms"] == now)
        print(f"PASS joined lobby as {you} ({args.transport}/{args.enc}, game protocol {welcome['game_protocol']})",
              flush=True)
        if not args.connect_only:
            await car.play(you, args.map, args.observe_seconds)
            car.print_sizes()
        await car.send("leave")
        await car.wait("status", lambda m: m["state"] == "disconnected", timeout=5)
        await assert_closed(socket)
        print("PASS clean disconnect", flush=True)


async def assert_closed(socket, rejected=False):
    try:
        await asyncio.wait_for(socket.recv(), timeout=5)
    except (ConnectionClosedOK, asyncio.IncompleteReadError):
        return
    except ConnectionClosedError as error:
        if rejected and error.rcvd is not None:
            return
        raise
    raise AssertionError("Expected the server to close")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--transport", choices=("ws", "tcp"), default="ws")
    parser.add_argument("--url", help="WebSocket URL, including wss://")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int)
    parser.add_argument("--enc", choices=("json", "bin"), default="json")
    parser.add_argument("--tier", choices=("thin", "full"), default="thin",
                        help="full is usable with --expect-error in a Thin-only build")
    parser.add_argument("--code", default=os.getenv("FALLOUT_THIN_JOIN_CODE"))
    parser.add_argument("--rate", type=int, choices=range(2, 21), default=20)
    parser.add_argument("--radius", type=float)
    parser.add_argument("--max-enemies", type=int)
    parser.add_argument("--name", default="Thin Client QA")
    parser.add_argument("--map", default="pinecrest")
    parser.add_argument("--connect-only", action="store_true")
    parser.add_argument("--expect-error", help="assert the handshake error contains this text")
    parser.add_argument("--require-results", action="store_true")
    parser.add_argument("--observe-seconds", type=float, default=5)
    parser.add_argument("--stall-after-load", type=float, default=0,
                        help="Block all client I/O for this many seconds immediately after load")
    parser.add_argument("--read-rate", type=float, default=0,
                        help="Limit application reads to this many messages per second (0 = unlimited)")
    parser.add_argument("--send-loaded", action="store_true", help="Send the optional loaded message")
    args = parser.parse_args()
    if any(not math.isfinite(value) or value < 0 for value in (args.stall_after_load, args.read_rate)):
        parser.error("--stall-after-load and --read-rate must be finite and nonnegative")
    try:
        asyncio.run(main(args))
    except Exception as error:
        raise SystemExit(f"FAIL {type(error).__name__}: {error}") from error
