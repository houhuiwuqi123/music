import SceneKit
import simd
import SwiftUI
import UIKit

/// One lit place on the globe: every online plaza user whose coarse location rounds to it.
struct CandyGlobeMarker: Identifiable, Equatable {
    var id: String
    var latitude: Double
    var longitude: Double
    var online: Bool
    var count: Int
}

/// A slowly turning, draggable globe (SceneKit). Land comes from the Natural Earth
/// 110m outlines in CandyEarthLand, painted into an equirectangular texture. The sphere
/// mesh and the marker positions share one lat/lon mapping, so they always line up.
struct CandyGlobeView: UIViewRepresentable {
    var markers: [CandyGlobeMarker]
    var selectedID: String?
    var dark: Bool
    var onSelect: (String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 30
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSelect = onSelect
        coordinator.apply(markers: markers, selectedID: selectedID, dark: dark)
    }

    static func dismantleUIView(_ view: SCNView, coordinator: Coordinator) {
        coordinator.detach()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject {
        var onSelect: ((String?) -> Void)?

        private let scene = SCNScene()
        private let camera = SCNNode()
        private let pitchNode = SCNNode()
        private let yawNode = SCNNode()
        private let globe = SCNNode()
        private let markerRoot = SCNNode()
        private weak var view: SCNView?
        private var displayLink: CADisplayLink?
        private var lastFrame: CFTimeInterval = 0

        private var yaw: Float = -2.0     // radians; -longitude of the point facing the viewer
        private var pitch: Float = 0.35   // radians; latitude of the point facing the viewer
        private var target: (yaw: Float, pitch: Float)?
        private var dragging = false
        private var idleSince = CACurrentMediaTime()

        private var dark: Bool?
        private var markers: [CandyGlobeMarker] = []
        private var selectedID: String?
        private var markerNodes: [String: SCNNode] = [:]

        override init() {
            super.init()
            let cam = SCNCamera()
            cam.usesOrthographicProjection = true
            cam.orthographicScale = 1.1
            cam.zNear = 0.1
            cam.zFar = 10
            camera.camera = cam
            camera.position = SCNVector3(0, 0, 4)
            scene.rootNode.addChildNode(camera)

            let ambient = SCNNode()
            ambient.light = SCNLight()
            ambient.light?.type = .ambient
            ambient.light?.intensity = 820
            scene.rootNode.addChildNode(ambient)
            let sun = SCNNode()
            sun.light = SCNLight()
            sun.light?.type = .directional
            sun.light?.intensity = 300
            sun.eulerAngles = SCNVector3(-0.5, -0.6, 0)
            scene.rootNode.addChildNode(sun)

            globe.geometry = Self.sphereGeometry()
            yawNode.addChildNode(globe)
            yawNode.addChildNode(markerRoot)
            pitchNode.addChildNode(yawNode)
            scene.rootNode.addChildNode(pitchNode)
            applyRotation()
        }

        func attach(to view: SCNView) {
            self.view = view
            view.scene = scene
            view.pointOfView = camera
            view.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pan(_:))))
            view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tap(_:))))
            let link = CADisplayLink(target: WeakTarget(self), selector: #selector(WeakTarget.step(_:)))
            link.preferredFramesPerSecond = 30
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        func detach() {
            displayLink?.invalidate()
            displayLink = nil
        }

        func apply(markers newMarkers: [CandyGlobeMarker], selectedID newSelection: String?, dark newDark: Bool) {
            if dark != newDark {
                dark = newDark
                let material = SCNMaterial()
                material.diffuse.contents = Self.texture(dark: newDark)
                material.lightingModel = .lambert
                material.isDoubleSided = true
                globe.geometry?.materials = [material]
                markerNodes.values.forEach { $0.removeFromParentNode() }
                markerNodes = [:]
                markers = []
            }
            if newSelection != selectedID, let id = newSelection, let marker = newMarkers.first(where: { $0.id == id }) {
                focus(latitude: marker.latitude, longitude: marker.longitude)
            }
            guard newMarkers != markers || newSelection != selectedID else { return }
            markers = newMarkers
            selectedID = newSelection
            rebuildMarkers()
        }

        // MARK: Markers

        private func rebuildMarkers() {
            let wanted = Set(markers.map(\.id))
            for (id, node) in markerNodes where !wanted.contains(id) {
                node.removeFromParentNode()
                markerNodes.removeValue(forKey: id)
            }
            for marker in markers {
                markerNodes[marker.id]?.removeFromParentNode()
                let node = makeMarker(marker, selected: marker.id == selectedID)
                markerRoot.addChildNode(node)
                markerNodes[marker.id] = node
            }
        }

        private func makeMarker(_ marker: CandyGlobeMarker, selected: Bool) -> SCNNode {
            let isDark = dark ?? false
            let base: UIColor = marker.online ? (isDark ? .white : UIColor(white: 0.08, alpha: 1))
                : UIColor(white: isDark ? 0.55 : 0.62, alpha: 1)
            let color = selected ? UIColor.systemPink : base
            let size = CGFloat(selected ? 0.034 : min(0.03, 0.018 + 0.003 * Double(max(0, marker.count - 1))))

            let node = SCNNode()
            node.name = marker.id
            node.position = Self.position(latitude: marker.latitude, longitude: marker.longitude, radius: 1.004)
            // Turn the plane's +Z normal to point outward: tilt to the latitude, then swing to the longitude.
            node.simdOrientation = simd_quatf(angle: Float(marker.longitude * .pi / 180), axis: SIMD3(0, 1, 0))
                * simd_quatf(angle: Float(-marker.latitude * .pi / 180), axis: SIMD3(1, 0, 0))

            let dot = SCNPlane(width: size, height: size)
            dot.cornerRadius = size * 0.18
            dot.firstMaterial?.diffuse.contents = color
            dot.firstMaterial?.lightingModel = .constant
            dot.firstMaterial?.isDoubleSided = true
            node.addChildNode(SCNNode(geometry: dot))

            if marker.online {
                let halo = SCNPlane(width: size * 3.2, height: size * 3.2)
                halo.cornerRadius = size * 1.6
                halo.firstMaterial?.diffuse.contents = color.withAlphaComponent(selected ? 0.35 : 0.22)
                halo.firstMaterial?.lightingModel = .constant
                halo.firstMaterial?.writesToDepthBuffer = false
                let haloNode = SCNNode(geometry: halo)
                haloNode.position = SCNVector3(0, 0, -0.001)
                let pulse = SCNAction.sequence([
                    .group([.scale(to: 1.25, duration: 1.1), .fadeOpacity(to: 0.15, duration: 1.1)]),
                    .group([.scale(to: 0.8, duration: 0.01), .fadeOpacity(to: 1, duration: 0.01)]),
                ])
                haloNode.runAction(.repeatForever(pulse))
                node.addChildNode(haloNode)
            }

            // Generous invisible hit area: real dots are a few points wide.
            let hit = SCNNode(geometry: SCNSphere(radius: 0.06))
            hit.geometry?.firstMaterial?.colorBufferWriteMask = []
            hit.geometry?.firstMaterial?.writesToDepthBuffer = false
            hit.name = marker.id
            node.addChildNode(hit)
            return node
        }

        // MARK: Motion

        private func focus(latitude: Double, longitude: Double) {
            let wantedYaw = Float(-longitude * .pi / 180)
            // Shortest way round.
            var delta = (wantedYaw - yaw).truncatingRemainder(dividingBy: 2 * .pi)
            if delta > .pi { delta -= 2 * .pi }
            if delta < -.pi { delta += 2 * .pi }
            target = (yaw + delta, Float(max(-60, min(60, latitude)) * .pi / 180))
        }

        fileprivate func step(_ link: CADisplayLink) {
            let now = link.timestamp
            let dt = Float(lastFrame == 0 ? 0 : min(0.1, now - lastFrame))
            lastFrame = now
            guard !dragging else { return }
            if let goal = target {
                let k = min(1, dt * 5)
                yaw += (goal.yaw - yaw) * k
                pitch += (goal.pitch - pitch) * k
                if abs(goal.yaw - yaw) < 0.001 && abs(goal.pitch - pitch) < 0.001 { target = nil }
                applyRotation()
            } else if selectedID == nil, now - idleSince > 2 {
                yaw += dt * 0.06
                applyRotation()
            }
        }

        private func applyRotation() {
            pitchNode.eulerAngles = SCNVector3(pitch, 0, 0)
            yawNode.eulerAngles = SCNVector3(0, yaw, 0)
        }

        @objc private func pan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            switch gesture.state {
            case .began:
                dragging = true
                target = nil
            case .changed:
                let translation = gesture.translation(in: view)
                gesture.setTranslation(.zero, in: view)
                let scale = Float(2.2 / max(1, view.bounds.width))
                yaw += Float(translation.x) * scale
                pitch = max(-1.2, min(1.2, pitch + Float(translation.y) * scale))
                applyRotation()
            default:
                dragging = false
                idleSince = CACurrentMediaTime()
            }
        }

        @objc private func tap(_ gesture: UITapGestureRecognizer) {
            guard let view else { return }
            let point = gesture.location(in: view)
            let hits = view.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.all.rawValue,
                                                     .ignoreHiddenNodes: false])
            // Closest hit first: a dot behind the globe is hidden by the globe itself.
            let id = hits.first.flatMap { hit -> String? in
                var node: SCNNode? = hit.node
                while let current = node {
                    if let name = current.name, markerNodes[name] != nil { return name }
                    node = current.parent
                }
                return nil
            }
            idleSince = CACurrentMediaTime()
            onSelect?(id)
        }

        // MARK: Geometry

        /// x = cos(lat)·sin(lon), y = sin(lat), z = cos(lat)·cos(lon): (0°, 0°) faces the camera.
        static func position(latitude: Double, longitude: Double, radius: Double) -> SCNVector3 {
            let lat = latitude * .pi / 180
            let lon = longitude * .pi / 180
            return SCNVector3(Float(radius * cos(lat) * sin(lon)), Float(radius * sin(lat)), Float(radius * cos(lat) * cos(lon)))
        }

        static func sphereGeometry(slices: Int = 120, stacks: Int = 60) -> SCNGeometry {
            var vertices: [SCNVector3] = []
            var uvs: [CGPoint] = []
            var indices: [UInt32] = []
            vertices.reserveCapacity((slices + 1) * (stacks + 1))
            for i in 0...stacks {
                let lat = 90 - 180 * Double(i) / Double(stacks)
                for j in 0...slices {
                    let lon = -180 + 360 * Double(j) / Double(slices)
                    vertices.append(position(latitude: lat, longitude: lon, radius: 1))
                    // SceneKit texture coordinates start at the image's top-left corner.
                    uvs.append(CGPoint(x: Double(j) / Double(slices), y: Double(i) / Double(stacks)))
                }
            }
            for i in 0..<stacks {
                for j in 0..<slices {
                    let a = UInt32(i * (slices + 1) + j)
                    let b = a + UInt32(slices + 1)
                    indices += [a, b, a + 1, a + 1, b, b + 1]
                }
            }
            let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
            return SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: vertices),
                                         SCNGeometrySource(textureCoordinates: uvs)], elements: [element])
        }

        private static var textures: [Bool: UIImage] = [:]

        static func texture(dark: Bool) -> UIImage {
            if let cached = textures[dark] { return cached }
            let size = CGSize(width: 2048, height: 1024)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let ocean = dark ? UIColor(white: 0.13, alpha: 1) : UIColor(red: 0.965, green: 0.965, blue: 0.955, alpha: 1)
            let land = dark ? UIColor(white: 0.27, alpha: 1) : UIColor(red: 0.89, green: 0.89, blue: 0.875, alpha: 1)
            let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                let cg = context.cgContext
                ocean.setFill()
                cg.fill(CGRect(origin: .zero, size: size))
                let path = CGMutablePath()
                for ring in CandyEarthLand.rings {
                    for (index, point) in ring.enumerated() {
                        let p = CGPoint(x: (point.0 + 180) / 360 * size.width, y: (90 - point.1) / 180 * size.height)
                        if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
                    }
                    path.closeSubpath()
                }
                cg.addPath(path)
                land.setFill()
                cg.fillPath(using: .evenOdd)
            }
            textures[dark] = image
            return image
        }
    }
}

/// CADisplayLink retains its target; this breaks the cycle with the coordinator.
private final class WeakTarget: NSObject {
    weak var coordinator: CandyGlobeView.Coordinator?
    init(_ coordinator: CandyGlobeView.Coordinator) { self.coordinator = coordinator }
    @MainActor @objc func step(_ link: CADisplayLink) { coordinator?.step(link) }
}
