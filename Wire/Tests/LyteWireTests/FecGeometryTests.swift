import XCTest
import LyteWire

final class FecGeometryTests: XCTestCase {

    func testBalancedSplitDerivations() throws {
        // 53 B over k=5: bs = ceil(53/5) = 11, trailing shard 9 B.
        let geometry = try FecGeometry(
            dataShards: 5, parityShards: 2, groupByteCount: 53
        )
        XCTAssertEqual(geometry.totalShards, 7)
        XCTAssertEqual(geometry.shardByteCount, 11)
        XCTAssertEqual(geometry.lastDataShardByteCount, 9)
        XCTAssertEqual(
            (0..<7).map(geometry.wireByteCount(ofShard:)),
            [11, 11, 11, 11, 9, 11, 11]
        )
        XCTAssertEqual(geometry.byteRange(ofDataShard: 0), 0..<11)
        XCTAssertEqual(geometry.byteRange(ofDataShard: 4), 44..<53)
        XCTAssertFalse(geometry.isParityShard(4))
        XCTAssertTrue(geometry.isParityShard(5))
    }

    func testExactMultipleHasNoShortShard() throws {
        let geometry = try FecGeometry(
            dataShards: 4, parityShards: 2, groupByteCount: 48
        )
        XCTAssertEqual(geometry.shardByteCount, 12)
        XCTAssertEqual(geometry.lastDataShardByteCount, 12)
    }

    func testShardByteCountNeverExceedsBudgetAtMinimalK() throws {
        // For k = ceil(len/1112) the balanced split stays within the
        // 1112 B plaintext budget at every group size shape.
        for byteCount in [1, 1112, 1113, 2224, 2225, 4449, 283_560 / 2] {
            let geometry = try FecGeometryTable.geometry(
                forGroupByteCount: byteCount, regime: .clean
            )
            XCTAssertLessThanOrEqual(
                geometry.shardByteCount, WireBudget.maxPlaintextShardByteCount,
                "byteCount \(byteCount)"
            )
            XCTAssertGreaterThan(
                geometry.lastDataShardByteCount, 0, "byteCount \(byteCount)"
            )
        }
    }

    func testValidationRejects() {
        XCTAssertThrowsError(
            try FecGeometry(dataShards: 0, parityShards: 1, groupByteCount: 10)
        ) { XCTAssertEqual($0 as? FecError, .dataShardsOutOfRange(0)) }

        XCTAssertThrowsError(
            try FecGeometry(dataShards: 256, parityShards: 0, groupByteCount: 10)
        ) { XCTAssertEqual($0 as? FecError, .dataShardsOutOfRange(256)) }

        XCTAssertThrowsError(
            try FecGeometry(dataShards: 200, parityShards: 60, groupByteCount: 10)
        ) { XCTAssertEqual($0 as? FecError, .parityShardsOutOfRange(60)) }

        XCTAssertThrowsError(
            try FecGeometry(dataShards: 1, parityShards: -1, groupByteCount: 10)
        ) { XCTAssertEqual($0 as? FecError, .parityShardsOutOfRange(-1)) }

        XCTAssertThrowsError(
            try FecGeometry(dataShards: 1, parityShards: 1, groupByteCount: 0)
        ) { XCTAssertEqual($0 as? FecError, .groupByteCountOutOfRange(0)) }

        XCTAssertThrowsError(
            try FecGeometry(dataShards: 1, parityShards: 1, groupByteCount: 1113)
        ) { XCTAssertEqual($0 as? FecError, .groupByteCountOutOfRange(1113)) }

        // 5 B cannot fill 4 shards: bs=2 leaves the trailing shard empty.
        XCTAssertThrowsError(
            try FecGeometry(dataShards: 4, parityShards: 1, groupByteCount: 5)
        ) {
            XCTAssertEqual(
                $0 as? FecError,
                .overProvisionedDataShards(dataShards: 4, groupByteCount: 5)
            )
        }
        // 7 B over 4 shards is fine: 2,2,2,1.
        XCTAssertNoThrow(
            try FecGeometry(dataShards: 4, parityShards: 1, groupByteCount: 7)
        )
    }

    func testFullBlockAtGF256Limit() throws {
        let geometry = try FecGeometry(
            dataShards: 204, parityShards: 51, groupByteCount: 204 * 1112
        )
        XCTAssertEqual(geometry.totalShards, 255)
        XCTAssertEqual(geometry.shardByteCount, 1112)
    }
}

final class FecGeometryTableTests: XCTestCase {

    // Resiliency §5.2, both columns, bucket edges and interiors — the
    // same expectations fec-v1.json freezes as geometryRows.
    private let expectations: [(k: Int, clean: Int?, lossy: Int?)] = [
        (1, 1, 2),
        (2, 1, 2),
        (3, 2, 2),        // lossy ceil(50%) = 2
        (4, 2, 2),
        (5, 2, 3),
        (8, 2, 4),
        (9, 2, 4),        // clean ceil(15%) = 2, lossy ceil(35%) = 4
        (20, 3, 7),
        (32, 5, 12),
        (33, 4, 9),       // clean ceil(10%) = 4, lossy ceil(25%) = 9
        (100, 10, 25),
        (204, 21, 51),    // lossy's last protectable k: 204 + 51 = 255
        (205, 21, nil),
        (231, 24, nil),   // clean's last protectable k: 231 + 24 = 255
        (232, nil, nil),
        (255, nil, nil),
    ]

    func testLadderValues() {
        for row in expectations {
            for (regime, expected) in [
                (FecRegime.clean, row.clean), (FecRegime.lossy, row.lossy),
            ] {
                if let expected {
                    XCTAssertEqual(
                        try FecGeometryTable.parityShards(
                            forDataShards: row.k, regime: regime
                        ),
                        expected,
                        "k=\(row.k) \(regime)"
                    )
                } else {
                    XCTAssertThrowsError(
                        try FecGeometryTable.parityShards(
                            forDataShards: row.k, regime: regime
                        ),
                        "k=\(row.k) \(regime)"
                    ) {
                        XCTAssertEqual(
                            $0 as? FecError,
                            .unprotectableDataShardCount(row.k)
                        )
                    }
                }
            }
        }
    }

    func testEveryProtectableKFitsTheBlock() throws {
        for regime in FecRegime.allCases {
            for k in 1...FecGeometryTable.maxDataShards(regime) {
                let m = try FecGeometryTable.parityShards(
                    forDataShards: k, regime: regime
                )
                XCTAssertGreaterThanOrEqual(m, 1, "k=\(k) \(regime)")
                XCTAssertLessThanOrEqual(k + m, 255, "k=\(k) \(regime)")
            }
        }
    }

    func testLossyNeverProtectsLessThanClean() throws {
        for k in 1...FecGeometryTable.maxDataShards(.lossy) {
            let clean = try FecGeometryTable.parityShards(
                forDataShards: k, regime: .clean
            )
            let lossy = try FecGeometryTable.parityShards(
                forDataShards: k, regime: .lossy
            )
            XCTAssertGreaterThanOrEqual(lossy, clean, "k=\(k)")
        }
    }

    func testMaxDataShards() {
        XCTAssertEqual(FecGeometryTable.maxDataShards(.clean), 231)
        XCTAssertEqual(FecGeometryTable.maxDataShards(.lossy), 204)
    }

    func testOutOfDomainK() {
        for k in [0, -1, 256] {
            for regime in FecRegime.allCases {
                XCTAssertThrowsError(
                    try FecGeometryTable.parityShards(
                        forDataShards: k, regime: regime
                    )
                ) {
                    XCTAssertEqual(
                        $0 as? FecError, .unprotectableDataShardCount(k)
                    )
                }
            }
        }
    }

    func testGeometryForGroupByteCountPicksMinimalK() throws {
        let small = try FecGeometryTable.geometry(
            forGroupByteCount: 100, regime: .clean
        )
        XCTAssertEqual(small.dataShards, 1)
        XCTAssertEqual(small.parityShards, 1)

        let audio = try FecGeometryTable.geometry(
            forGroupByteCount: 3 * 1112 + 1, regime: .clean
        )
        XCTAssertEqual(audio.dataShards, 4)
        XCTAssertEqual(audio.parityShards, 2)

        let lossyBig = try FecGeometryTable.geometry(
            forGroupByteCount: 40 * 1112, regime: .lossy
        )
        XCTAssertEqual(lossyBig.dataShards, 40)
        XCTAssertEqual(lossyBig.parityShards, 10)

        // One byte past the lossy frame ceiling is unprotectable.
        XCTAssertThrowsError(
            try FecGeometryTable.geometry(
                forGroupByteCount: 204 * 1112 + 1, regime: .lossy
            )
        ) {
            XCTAssertEqual($0 as? FecError, .unprotectableDataShardCount(205))
        }
    }
}
