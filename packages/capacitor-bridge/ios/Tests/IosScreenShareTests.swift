// Copyright (c) DeskFleet contributors. Licensed under the Apache License, Version 2.0.
import Foundation
import XCTest
@testable import DeskFleetLocalFiles

final class IosScreenShareTests: XCTestCase {
    func testParseVideoAndReplayKitStartRequestsClampParameters() {
        let req = IosScreenShareProtocol.parseVideoRequest("VIDEO hevc 120 99999999 1920 1080")
        XCTAssertEqual(
            req,
            IosScreenShareProtocol.VideoStreamRequest(
                codec: "h265",
                fps: 60,
                bitrateBps: 25_000_000,
                maxWidth: 1920,
                maxHeight: 1080
            )
        )

        let encoded = IosScreenShareProtocol.encodeReplayKitStartCommand(req!)
        let roundTripped = IosScreenShareProtocol.parseReplayKitStartCommand(String(decoding: encoded, as: UTF8.self))
        XCTAssertEqual(roundTripped, req)

        XCTAssertNil(IosScreenShareProtocol.parseVideoRequest("VIDEO vp9 30 4000000 0 0"))
        XCTAssertNil(IosScreenShareProtocol.parseVideoRequest("INFO"))
    }

    func testComputeScaledEvenDimensionsPreservesAspectRatioAndEvenness() {
        let unchanged = IosScreenShareProtocol.computeScaledEvenDimensions(
            srcWidth: 1179,
            srcHeight: 2556,
            maxWidth: 0,
            maxHeight: 0
        )
        XCTAssertEqual(unchanged.width, 1178)
        XCTAssertEqual(unchanged.height, 2556)

        let scaled = IosScreenShareProtocol.computeScaledEvenDimensions(
            srcWidth: 1179,
            srcHeight: 2556,
            maxWidth: 1280,
            maxHeight: 1280
        )
        XCTAssertEqual(scaled.height, 1280)
        XCTAssertEqual(scaled.width % 2, 0)
        XCTAssertEqual(scaled.height % 2, 0)
        XCTAssertEqual(scaled.width, 588)
    }

    func testConvertLengthPrefixedToAnnexBPrependsParameterSetsOnKeyframes() {
        let sps = Data([0x67, 0x42, 0xE0, 0x28])
        let pps = Data([0x68, 0xCE, 0x3C, 0x80])
        let idr = Data([0x65, 0x88, 0x84])
        var avcc = Data()
        var idrLen = UInt32(idr.count).bigEndian
        withUnsafeBytes(of: &idrLen) { avcc.append(contentsOf: $0) }
        avcc.append(idr)

        let keyframe = IosScreenShareProtocol.convertLengthPrefixedToAnnexB(
            avccData: avcc,
            parameterSets: [sps, pps],
            prependParameterSets: true
        )
        let expectedKeyframe = Data([
            0, 0, 0, 1, 0x67, 0x42, 0xE0, 0x28,
            0, 0, 0, 1, 0x68, 0xCE, 0x3C, 0x80,
            0, 0, 0, 1, 0x65, 0x88, 0x84,
        ])
        XCTAssertEqual(keyframe, expectedKeyframe)

        let delta = IosScreenShareProtocol.convertLengthPrefixedToAnnexB(
            avccData: avcc,
            parameterSets: [sps, pps],
            prependParameterSets: false
        )
        XCTAssertEqual(delta, Data([0, 0, 0, 1, 0x65, 0x88, 0x84]))

        let split = IosScreenShareProtocol.splitAnnexBNalUnits(keyframe)
        XCTAssertEqual(split, [sps, pps, idr])
    }

    func testVideoFrameEncodeAndDecodeRoundTrip() {
        let payload = Data([0x00, 0x00, 0x00, 0x01, 0x26, 0x01])
        let framed = IosScreenShareProtocol.encodeVideoFrame(
            payload: payload,
            ptsNs: 123_456_789,
            isKeyframe: true
        )
        XCTAssertEqual(framed.count, 14 + payload.count)
        let header = IosScreenShareProtocol.decodeFrameHeader(framed.prefix(14))
        XCTAssertEqual(header?.kind, IosScreenShareProtocol.frameKindVideo)
        XCTAssertEqual(header?.flags, IosScreenShareProtocol.frameFlagKeyframe)
        XCTAssertEqual(header?.ptsNs, 123_456_789)
        XCTAssertEqual(header?.length, payload.count)
        XCTAssertEqual(framed.dropFirst(14), payload)

        let keepalive = IosScreenShareProtocol.encodeKeepaliveFrame()
        let kaHeader = IosScreenShareProtocol.decodeFrameHeader(keepalive)
        XCTAssertEqual(kaHeader?.kind, IosScreenShareProtocol.frameKindKeepalive)
        XCTAssertEqual(kaHeader?.length, 0)
    }

    func testParseCoreDeviceProbeJsonAndEncodeGuestInfo() {
        let probe = IosScreenShareProtocol.parseCoreDeviceProbeJson(
            #"{"available":true,"control":true,"pasteboard":true,"codecs":["h265"]}"#
        )
        XCTAssertEqual(
            probe,
            IosScreenShareProtocol.CoreDeviceProbeResult(
                available: true,
                control: true,
                pasteboard: true,
                codecs: ["h265"]
            )
        )

        let infoJson = IosScreenShareProtocol.encodeGuestInfoJson(
            available: true,
            control: true,
            width: 1179,
            height: 2556,
            fps: 60.0,
            codecs: ["h265"]
        )
        XCTAssertTrue(infoJson.contains(#""available":true"#))
        XCTAssertTrue(infoJson.contains(#""control":true"#))
        XCTAssertTrue(infoJson.contains(#""width":1179"#))
        XCTAssertTrue(infoJson.contains(#""codecs":["h265"]"#))
    }
}
