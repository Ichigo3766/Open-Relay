import SwiftUI
import Charts

// MARK: - Chart Rendering
//
// Renders LLM-generated chart specifications as native Swift Charts.
// Supports Chart.js, Plotly (scatter, line, bar, pie, heatmap, histogram),
// ECharts, Highcharts, Vega-Lite (subset), and flat pie/custom schemas.
//
// Adapted from stream-chat-swift-ai Charts.swift (MIT-adjacent license).
// Only the chart spec parsing + rendering is extracted — no dependency
// on the StreamChatAI library itself.

// MARK: - Unified Internal Model (USpec)

/// The type of chart to render.
enum ChartKind: String {
    case line, bar, area, scatter, bubble, pie, heatmap, histogram
}

/// A single data point in a chart series.
struct UPoint: Identifiable, Hashable {
    var id: String { "\(x)|\(y)|\(size ?? -1)|\(z ?? -1)" }
    let x: String           // category or stringified number/date
    let y: Double
    let size: Double?       // for bubble charts
    let z: Double?          // for heatmap intensity
    init(x: String, y: Double, size: Double? = nil, z: Double? = nil) {
        self.x = x; self.y = y; self.size = size; self.z = z
    }
}

/// A named series of data points.
struct USeries: Identifiable {
    let id = UUID()
    let name: String
    let points: [UPoint]
    init(name: String, points: [UPoint]) { self.name = name; self.points = points }
}

/// A unified chart specification that all format parsers produce.
struct USpec {
    let title: String?
    let kind: ChartKind
    let xLabel: String?
    let yLabel: String?
    let beginAtZeroY: Bool
    let series: [USeries]
    init(title: String?, kind: ChartKind, xLabel: String? = nil, yLabel: String? = nil, beginAtZeroY: Bool = false, series: [USeries]) {
        self.title = title; self.kind = kind; self.xLabel = xLabel; self.yLabel = yLabel; self.beginAtZeroY = beginAtZeroY; self.series = series
    }
}

// MARK: - Language Tags That Trigger Chart Rendering

/// Code block language tags that should attempt chart parsing.
let chartLanguageTags: Set<String> = [
    "json", "chart", "chartjs", "echarts", "highcharts",
    "vega-lite", "vegalite", "plotly"
]

// MARK: - Top-Level Parser

private enum ParsedSpecError: Error { case unsupported }

/// Attempts to parse raw JSON data into a unified `USpec` chart model.
/// Tries all supported formats in order: Chart.js, Plotly, ECharts,
/// Highcharts, Vega-Lite, custom schema, flat pie.
func parseUSpec(from jsonData: Data) throws -> USpec {
    // 1) Chart.js (+ pie/doughnut + scatter + bubble)
    if let j = try? JSONDecoder().decode(ChartJSSpec.self, from: jsonData) {
        if let pie = mapChartJSPieIfAny(j) { return pie }
        return mapChartJSGeneral(j)
    }
    // 1b) Plotly (heatmap): single-spec and figure
    if let p = try? JSONDecoder().decode(PlotlySingleSpec.self, from: jsonData), p.type.lowercased() == "heatmap" {
        return mapPlotlySingleHeatmap(p)
    }
    if let fig = try? JSONDecoder().decode(PlotlyFigure.self, from: jsonData), let mapped = mapPlotlyFigure(fig) {
        return mapped
    }
    // 2) ECharts
    if let e = try? JSONDecoder().decode(EChartsSpec.self, from: jsonData) {
        return mapECharts(e)
    }
    // 3) Highcharts
    if let h = try? JSONDecoder().decode(HighchartsSpec.self, from: jsonData) {
        return mapHighcharts(h)
    }
    // 4) Vega-Lite (subset)
    if let v = try? JSONDecoder().decode(VegaLiteSpec.self, from: jsonData) {
        return try mapVegaLite(v)
    }
    // 5) Custom schema (line/bar/area/scatter)
    if let c = try? JSONDecoder().decode(CustomChartSpec.self, from: jsonData) {
        return mapCustom(c)
    }
    // 6) Flat pie schema
    if let p = try? JSONDecoder().decode(PieFlatSpec.self, from: jsonData), p.type.lowercased() == "pie" {
        return mapPieFlat(p)
    }
    throw ParsedSpecError.unsupported
}

// MARK: - Custom Schema

private struct CustomPoint: Decodable { let x: String; let y: Double }
private struct CustomSeries: Decodable { let name: String; let points: [CustomPoint] }
private struct CustomChartSpec: Decodable {
    let title: String?
    let x_label: String?
    let y_label: String?
    let chart_type: String
    let series: [CustomSeries]
}
private func mapCustom(_ c: CustomChartSpec) -> USpec {
    let kind = ChartKind(rawValue: c.chart_type.lowercased()) ?? .line
    let series = c.series.map { USeries(name: $0.name, points: $0.points.map { UPoint(x: $0.x, y: $0.y) }) }
    return USpec(title: c.title, kind: kind, xLabel: c.x_label, yLabel: c.y_label, beginAtZeroY: false, series: series)
}

// MARK: - Flat Pie

private struct PieFlatItem: Decodable { let label: String; let value: Double }
private struct PieFlatSpec: Decodable { let type: String; let title: String?; let data: [PieFlatItem] }
private func mapPieFlat(_ p: PieFlatSpec) -> USpec {
    let s = USeries(name: p.title ?? "Pie", points: p.data.map { UPoint(x: $0.label, y: $0.value) })
    return USpec(title: p.title, kind: .pie, series: [s])
}

// MARK: - Chart.js

private struct ChartJSDatasetValue: Decodable {
    var x: Double?; var y: Double?; var r: Double?
    init(x: Double? = nil, y: Double? = nil, r: Double? = nil) {
        self.x = x; self.y = y; self.r = r
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let num = try? c.decode(Double.self) {
            self.x = nil; self.y = num; self.r = nil
        } else if let obj = try? c.decode([String: Double].self) {
            self.x = obj["x"]; self.y = obj["y"]; self.r = obj["r"]
        } else { self.x = nil; self.y = nil; self.r = nil }
    }
}
private struct ChartJSDataset: Decodable { let label: String?; let data: [ChartJSDatasetValue] }
private struct ChartJSData: Decodable { let labels: [String]?; let datasets: [ChartJSDataset] }
private struct ChartJSOptions: Decodable { let scales: ChartJSScales? }
private struct ChartJSScales: Decodable { let y: ChartJSScaleY? }
private struct ChartJSScaleY: Decodable { let beginAtZero: Bool? }
private struct ChartJSSpec: Decodable {
    let title: String?; let type: String; let data: ChartJSData; let options: ChartJSOptions?
}

private func mapChartJSPieIfAny(_ j: ChartJSSpec) -> USpec? {
    let t = j.type.lowercased()
    guard t == "pie" || t == "doughnut" else { return nil }
    guard let ds = j.data.datasets.first else { return nil }
    let labels = j.data.labels ?? Array(0..<ds.data.count).map(String.init)
    let points: [UPoint] = zip(labels, ds.data).compactMap { (lbl, v) in
        if let y = v.y { return UPoint(x: lbl, y: y) } else { return nil }
    }
    return USpec(title: j.title, kind: .pie, series: [USeries(name: ds.label ?? "Pie", points: points)])
}

private func mapChartJSGeneral(_ j: ChartJSSpec) -> USpec {
    let type = j.type.lowercased()
    let begin0 = j.options?.scales?.y?.beginAtZero ?? false
    let series: [USeries] = j.data.datasets.map { ds in
        if let labels = j.data.labels {
            var pts: [UPoint] = []
            for (idx, lbl) in labels.enumerated() {
                let v = idx < ds.data.count ? ds.data[idx] : ChartJSDatasetValue()
                if let y = v.y { pts.append(UPoint(x: lbl, y: y, size: v.r)) }
            }
            return USeries(name: ds.label ?? "Series", points: pts)
        } else {
            let pts = ds.data.compactMap { v -> UPoint? in
                guard let x = v.x, let y = v.y else { return nil }
                return UPoint(x: String(x), y: y, size: v.r)
            }
            return USeries(name: ds.label ?? "Series", points: pts)
        }
    }
    let kind: ChartKind = {
        switch type {
        case "line": return .line; case "bar": return .bar; case "area": return .area
        case "scatter": return .scatter; case "bubble": return .bubble
        case "radar": return .bar; case "polararea": return .pie
        default: return .line
        }
    }()
    return USpec(title: j.title, kind: kind, beginAtZeroY: begin0, series: series)
}

// MARK: - ECharts

private struct EChartsSeries: Decodable {
    let name: String?; let type: String?; let data: [EChartsDatum]
}
private enum EChartsDatum: Decodable {
    case number(Double); case pair([Double]); case obj([String: ChartAnyDecodable])
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let arr = try? c.decode([Double].self) { self = .pair(arr); return }
        if let obj = try? c.decode([String: ChartAnyDecodable].self) { self = .obj(obj); return }
        self = .number(0)
    }
}
private struct EChartsSpec: Decodable {
    let title: ChartTitleWrapper?; let xAxis: EAxis?; let yAxis: EAxis?; let series: [EChartsSeries]
}
private struct ChartTitleWrapper: Decodable { let text: String? }
private struct EAxis: Decodable { let data: [String]?; let type: String? }

private func mapECharts(_ e: EChartsSpec) -> USpec {
    let title = e.title?.text
    let categories = e.xAxis?.data
    var allSeries: [USeries] = []
    for s in e.series {
        let name = s.name ?? "Series"
        var pts: [UPoint] = []
        switch s.type?.lowercased() {
        case "pie":
            for d in s.data {
                if case .obj(let obj) = d,
                   let nameVal = obj["name"]?.string,
                   let valueVal = obj["value"]?.double {
                    pts.append(UPoint(x: nameVal, y: valueVal))
                }
            }
        default:
            if let cats = categories {
                for (idx, d) in s.data.enumerated() {
                    let x = idx < cats.count ? cats[idx] : String(idx)
                    switch d {
                    case .number(let v): pts.append(UPoint(x: x, y: v))
                    case .pair(let arr): if arr.count >= 2 { pts.append(UPoint(x: String(arr[0]), y: arr[1])) }
                    case .obj(let obj): if let v = obj["value"]?.double { pts.append(UPoint(x: x, y: v)) }
                    }
                }
            } else {
                for d in s.data {
                    switch d {
                    case .number(let v): pts.append(UPoint(x: String(pts.count), y: v))
                    case .pair(let arr): if arr.count >= 2 { pts.append(UPoint(x: String(arr[0]), y: arr[1])) }
                    case .obj(let obj):
                        if let v = obj["value"]?.double,
                           let x = obj["name"]?.string ?? obj["x"]?.string {
                            pts.append(UPoint(x: x, y: v))
                        }
                    }
                }
            }
        }
        allSeries.append(USeries(name: name, points: pts))
    }
    let firstType = e.series.first?.type?.lowercased()
    let kind: ChartKind = {
        switch firstType {
        case "bar": return .bar; case "line": return .line
        case "scatter": return .scatter; case "pie": return .pie
        default: return .line
        }
    }()
    return USpec(title: title, kind: kind, series: allSeries)
}

// MARK: - Highcharts

private struct HighchartsSeries: Decodable {
    let name: String?; let type: String?; let data: [HighchartsDatum]
}
private enum HighchartsDatum: Decodable {
    case number(Double); case pair([Double])
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let arr = try? c.decode([Double].self) { self = .pair(arr); return }
        self = .number(0)
    }
}
private struct HighchartsXAxis: Decodable { let categories: [String]? }
private struct HighchartsSpec: Decodable {
    let title: HCTitle?; let xAxis: HighchartsXAxis?; let series: [HighchartsSeries]
}
private struct HCTitle: Decodable { let text: String? }

private func mapHighcharts(_ h: HighchartsSpec) -> USpec {
    let title = h.title?.text
    let categories = h.xAxis?.categories
    let series: [USeries] = h.series.map { s in
        let name = s.name ?? "Series"
        var pts: [UPoint] = []
        if let cats = categories {
            for (idx, v) in s.data.enumerated() {
                let x = idx < cats.count ? cats[idx] : String(idx)
                switch v {
                case .number(let n): pts.append(UPoint(x: x, y: n))
                case .pair(let arr): if arr.count >= 2 { pts.append(UPoint(x: String(arr[0]), y: arr[1])) }
                }
            }
        } else {
            for v in s.data {
                switch v {
                case .number(let n): pts.append(UPoint(x: String(pts.count), y: n))
                case .pair(let arr): if arr.count >= 2 { pts.append(UPoint(x: String(arr[0]), y: arr[1])) }
                }
            }
        }
        return USeries(name: name, points: pts)
    }
    let kind: ChartKind = {
        switch h.series.first?.type?.lowercased() {
        case "bar", "column": return .bar; case "line", "spline": return .line
        case "scatter": return .scatter; case "pie": return .pie
        default: return .line
        }
    }()
    return USpec(title: title, kind: kind, series: series)
}

// MARK: - Vega-Lite (Subset)

private struct VegaLiteSpec: Decodable {
    let schema: String?; let data: VegaData; let mark: VegaMark; let encoding: VegaEncoding
    enum CodingKeys: String, CodingKey { case schema = "$schema", data, mark, encoding }
}
private struct VegaData: Decodable { let values: [VegaRow]? }
private struct VegaRow: Decodable {
    let raw: [String: ChartAnyDecodable]
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        raw = (try? c.decode([String: ChartAnyDecodable].self)) ?? [:]
    }
}
private enum VegaMark: Decodable {
    case str(String)
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = (try? c.decode(String.self))?.lowercased() ?? "point"
        self = .str(s)
    }
}
private struct VegaFieldRef: Decodable { let field: String? }
private struct VegaEncoding: Decodable {
    let x: VegaFieldRef?; let y: VegaFieldRef?; let color: VegaFieldRef?; let size: VegaFieldRef?
}

private func mapVegaLite(_ v: VegaLiteSpec) throws -> USpec {
    guard let rows = v.data.values else { throw ParsedSpecError.unsupported }
    let xField = v.encoding.x?.field ?? "x"
    let yField = v.encoding.y?.field ?? "y"
    let colorField = v.encoding.color?.field
    let sizeField = v.encoding.size?.field

    var groups: [String: [UPoint]] = [:]
    for r in rows {
        let xStr = r.raw[xField]?.string ?? String(r.raw[xField]?.double ?? 0)
        let yVal = r.raw[yField]?.double ?? 0
        let key = colorField.flatMap { r.raw[$0]?.string } ?? "Series"
        let sizeVal = sizeField.flatMap { r.raw[$0]?.double }
        groups[key, default: []].append(UPoint(x: xStr, y: yVal, size: sizeVal))
    }
    let series = groups.map { USeries(name: $0.key, points: $0.value) }
    let kind: ChartKind = {
        if case let .str(s) = v.mark {
            switch s {
            case "line": return .line; case "bar": return .bar; case "area": return .area
            case "point": return .scatter; case "rect": return .heatmap
            default: return .line
            }
        } else { return .line }
    }()
    return USpec(title: nil, kind: kind, series: series)
}

// MARK: - Plotly

private struct PlotlyLayoutAxisTitle: Decodable {
    let text: String?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { text = s }
        else if let obj = try? c.decode([String: String].self) { text = obj["text"] }
        else { text = nil }
    }
}
private struct PlotlyAxis: Decodable { let title: PlotlyLayoutAxisTitle? }
private struct PlotlyLayout: Decodable {
    let title: PlotlyLayoutAxisTitle?; let xaxis: PlotlyAxis?; let yaxis: PlotlyAxis?
}
private struct PlotlyHeatmapDataSingle: Decodable {
    let z: [[Double]]; let x: [String]?; let y: [String]?
}
private struct PlotlySingleSpec: Decodable {
    let type: String; let data: PlotlyHeatmapDataSingle; let layout: PlotlyLayout?
}

/// Flexible array that accepts both strings and numbers, storing everything as strings.
private struct PlotlyStringArray: Decodable {
    let values: [String]
    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [String] = []
        while !container.isAtEnd {
            if let s = try? container.decode(String.self) { result.append(s) }
            else if let d = try? container.decode(Double.self) { result.append(String(d)) }
            else if let i = try? container.decode(Int.self) { result.append(String(i)) }
            else { _ = try? container.decode(ChartAnyDecodable.self); result.append("") }
        }
        values = result
    }
}

/// Flexible array that accepts both strings and numbers, storing everything as doubles.
private struct PlotlyNumberArray: Decodable {
    let values: [Double]
    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [Double] = []
        while !container.isAtEnd {
            if let d = try? container.decode(Double.self) { result.append(d) }
            else if let s = try? container.decode(String.self) { result.append(Double(s) ?? 0) }
            else { _ = try? container.decode(ChartAnyDecodable.self); result.append(0) }
        }
        values = result
    }
}

/// A Plotly trace that handles all common chart types.
/// `x` can be strings or numbers; `y` can be numbers or strings.
/// `z` is used for heatmaps. `labels`/`values` are used for pie charts.
private struct PlotlyTrace: Decodable {
    let type: String?
    let mode: String?
    let name: String?
    let x: PlotlyStringArray?
    let y: PlotlyNumberArray?
    let z: [[Double]]?
    let labels: [String]?
    let values: [Double]?
    let text: PlotlyStringArray?
    let orientation: String?
}

private struct PlotlyFigure: Decodable {
    let data: [PlotlyTrace]; let layout: PlotlyLayout?
}

private func mapPlotlySingleHeatmap(_ p: PlotlySingleSpec) -> USpec {
    let z = p.data.z
    let xCats = p.data.x ?? (z.first?.indices.map { String($0) } ?? [])
    let yCats = p.data.y ?? z.indices.map { String($0) }
    var series: [USeries] = []
    for (i, row) in z.enumerated() {
        let yName = i < yCats.count ? yCats[i] : String(i)
        var pts: [UPoint] = []
        for (j, val) in row.enumerated() {
            let xName = j < xCats.count ? xCats[j] : String(j)
            pts.append(UPoint(x: xName, y: 0, z: val))
        }
        series.append(USeries(name: yName, points: pts))
    }
    return USpec(title: p.layout?.title?.text, kind: .heatmap,
                 xLabel: p.layout?.xaxis?.title?.text, yLabel: p.layout?.yaxis?.title?.text,
                 beginAtZeroY: false, series: series)
}

/// Maps a full Plotly figure with support for scatter, line, bar, pie,
/// heatmap, histogram, and other common trace types.
private func mapPlotlyFigure(_ f: PlotlyFigure) -> USpec? {
    guard !f.data.isEmpty else { return nil }

    let layout = f.layout
    let titleText = layout?.title?.text
    let xLabel = layout?.xaxis?.title?.text
    let yLabel = layout?.yaxis?.title?.text

    // Check if any trace is a heatmap
    if let heatTrace = f.data.first(where: { ($0.type?.lowercased() == "heatmap") && $0.z != nil }) {
        let z = heatTrace.z!
        let xCats = heatTrace.x?.values ?? (z.first?.indices.map { String($0) } ?? [])
        let yCats = heatTrace.labels ?? z.indices.map { String($0) }
        var series: [USeries] = []
        for (i, row) in z.enumerated() {
            let yName = i < yCats.count ? yCats[i] : String(i)
            var pts: [UPoint] = []
            for (j, val) in row.enumerated() {
                let xName = j < xCats.count ? xCats[j] : String(j)
                pts.append(UPoint(x: xName, y: 0, z: val))
            }
            series.append(USeries(name: yName, points: pts))
        }
        return USpec(title: titleText, kind: .heatmap, xLabel: xLabel, yLabel: yLabel,
                     beginAtZeroY: false, series: series)
    }

    // Check for pie/donut traces
    if let pieTrace = f.data.first(where: { ($0.type?.lowercased() == "pie") }) {
        if let labels = pieTrace.labels, let values = pieTrace.values {
            let pts = zip(labels, values).map { UPoint(x: $0, y: $1) }
            let s = USeries(name: pieTrace.name ?? "Pie", points: pts)
            return USpec(title: titleText, kind: .pie, xLabel: xLabel, yLabel: yLabel, series: [s])
        }
    }

    // Handle general xy traces: scatter, bar, line, area, histogram, etc.
    var allSeries: [USeries] = []
    var detectedKind: ChartKind = .line

    for (index, trace) in f.data.enumerated() {
        let traceType = trace.type?.lowercased() ?? "scatter"
        let traceMode = trace.mode?.lowercased() ?? ""
        let traceName = trace.name ?? (f.data.count == 1 ? "Series" : "Series \(index + 1)")

        // Determine chart kind from the first trace
        if index == 0 {
            detectedKind = plotlyTraceKind(type: traceType, mode: traceMode)
        }

        // Handle histogram (only y or only x values with binning)
        if traceType == "histogram" {
            if let yVals = trace.y?.values, !yVals.isEmpty {
                let pts = yVals.enumerated().map { UPoint(x: String($0.offset), y: $0.element) }
                allSeries.append(USeries(name: traceName, points: pts))
            } else if let xVals = trace.x?.values, !xVals.isEmpty {
                // x-histogram: count occurrences or treat as raw values
                let numericVals = xVals.compactMap { Double($0) }
                if !numericVals.isEmpty {
                    let pts = numericVals.enumerated().map { UPoint(x: String($0.offset), y: $0.element) }
                    allSeries.append(USeries(name: traceName, points: pts))
                }
            }
            detectedKind = .histogram
            continue
        }

        // Standard x/y traces (scatter, bar, line, area, etc.)
        guard let yVals = trace.y?.values, !yVals.isEmpty else { continue }

        let xVals: [String]
        if let traceX = trace.x?.values, !traceX.isEmpty {
            xVals = traceX
        } else {
            // Auto-generate x labels as indices
            xVals = yVals.indices.map { String($0) }
        }

        var pts: [UPoint] = []
        let count = min(xVals.count, yVals.count)
        for i in 0..<count {
            pts.append(UPoint(x: xVals[i], y: yVals[i]))
        }
        allSeries.append(USeries(name: traceName, points: pts))
    }

    guard !allSeries.isEmpty else { return nil }

    return USpec(title: titleText, kind: detectedKind, xLabel: xLabel, yLabel: yLabel,
                 beginAtZeroY: false, series: allSeries)
}

/// Converts a Plotly trace type + mode into our unified `ChartKind`.
private func plotlyTraceKind(type: String, mode: String) -> ChartKind {
    switch type {
    case "bar":
        return .bar
    case "pie":
        return .pie
    case "heatmap":
        return .heatmap
    case "histogram", "histogram2d":
        return .histogram
    case "scatter", "scattergl":
        // In Plotly, "scatter" with mode "lines" = line chart,
        // "markers" = scatter, "lines+markers" = line chart
        if mode.contains("lines") { return .line }
        return .scatter
    case "scatter3d":
        return .scatter
    default:
        // "scatterpolar", "funnel", etc. — best effort
        if mode.contains("lines") { return .line }
        return .line
    }
}

// MARK: - AnyDecodable Helper

/// A type-erased `Decodable` value for polymorphic JSON fields.
struct ChartAnyDecodable: Decodable {
    let value: Any
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Double.self) { value = v; return }
        if let v = try? c.decode(Int.self) { value = Double(v); return }
        if let v = try? c.decode(String.self) { value = v; return }
        if let v = try? c.decode(Bool.self) { value = v; return }
        if let v = try? c.decode([String: ChartAnyDecodable].self) { value = v; return }
        if let v = try? c.decode([ChartAnyDecodable].self) { value = v; return }
        value = NSNull()
    }
    var string: String? { value as? String }
    var double: Double? {
        if let d = value as? Double { return d }
        if let b = value as? Bool { return b ? 1 : 0 }
        return nil
    }
}

// MARK: - Chart Preview View (with Chart/Source toggle)

/// Wraps `USpecChartView` with a header bar providing:
/// - **Chart/Source toggle** — switch between rendered chart and raw JSON
/// - **Copy button** — copies the raw JSON source to clipboard
/// - Language label showing the detected chart type
///
/// Matches the style of `HTMLPreviewView` for visual consistency.
struct ChartPreviewView: View {
    let spec: USpec
    let rawCode: String
    let language: String

    @State private var showSource = false
    @State private var codeCopied = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            // ── Header bar ──
            HStack(spacing: 12) {
                // Chart type label
                HStack(spacing: 4) {
                    Image(systemName: chartIcon)
                        .font(.system(size: 10, weight: .semibold))
                    Text(spec.kind.rawValue)
                        .font(.system(.caption, design: .monospaced))
                        .fontWeight(.semibold)
                }
                .foregroundStyle(.secondary)

                Spacer()

                // Chart/Source toggle
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showSource.toggle()
                    }
                    Haptics.play(.light)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showSource ? "chart.bar" : "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 11, weight: .medium))
                        Text(showSource ? "Chart" : "Source")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                // Copy button
                Button {
                    UIPasteboard.general.string = rawCode
                    Haptics.notify(.success)
                    withAnimation(.spring()) { codeCopied = true }
                    Task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        withAnimation(.spring()) { codeCopied = false }
                    }
                } label: {
                    Group {
                        if codeCopied {
                            Label("Copied", systemImage: "checkmark")
                                .transition(.opacity.combined(with: .scale))
                        } else {
                            Label("Copy", systemImage: "square.on.square")
                                .transition(.opacity.combined(with: .scale))
                        }
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
            .background(.quaternary.opacity(0.3))

            Divider()

            // ── Content ──
            ZStack {
                if showSource {
                    // Syntax-highlighted JSON source (headerless — parent has the toolbar)
                    HighlightedSourceView(code: rawCode, language: language)
                        .transition(.opacity)
                } else {
                    // Rendered chart
                    USpecChartView(spec: spec)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: showSource)
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.quaternary)
        )
    }

    /// Returns an SF Symbol name for the chart type.
    private var chartIcon: String {
        switch spec.kind {
        case .line: return "chart.xyaxis.line"
        case .bar: return "chart.bar"
        case .area: return "chart.line.uptrend.xyaxis"
        case .scatter: return "chart.dots.scatter"
        case .bubble: return "circle.circle"
        case .pie: return "chart.pie"
        case .heatmap: return "square.grid.3x3"
        case .histogram: return "chart.bar.xaxis"
        }
    }
}

// MARK: - Chart Renderer View

/// Renders a `USpec` as a native Swift Chart.
///
/// Supports line, bar, area, scatter, bubble, pie (iOS 17+),
/// heatmap, and histogram chart types.
struct USpecChartView: View {
    let spec: USpec

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = spec.title {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
            }

            Group {
                switch spec.kind {
                case .pie:
                    pieChart
                case .heatmap:
                    heatmapChart
                case .histogram:
                    histogramChart
                case .bubble:
                    bubbleChart
                case .scatter, .line, .bar, .area:
                    standardChart
                }
            }
            .frame(height: 260)
        }
        .padding(12)
    }

    // MARK: Standard Charts (line, bar, area, scatter)

    @ViewBuilder
    private var standardChart: some View {
        Chart {
            ForEach(spec.series) { s in
                switch spec.kind {
                case .bar:
                    ForEach(s.points) { p in
                        BarMark(x: .value(spec.xLabel ?? "X", p.x),
                                y: .value(spec.yLabel ?? "Y", p.y))
                        .foregroundStyle(by: .value("Series", s.name))
                    }
                case .area:
                    ForEach(s.points) { p in
                        AreaMark(x: .value(spec.xLabel ?? "X", p.x),
                                 y: .value(spec.yLabel ?? "Y", p.y))
                        .foregroundStyle(by: .value("Series", s.name))
                    }
                case .line:
                    ForEach(s.points) { p in
                        LineMark(x: .value(spec.xLabel ?? "X", p.x),
                                 y: .value(spec.yLabel ?? "Y", p.y))
                        .foregroundStyle(by: .value("Series", s.name))
                    }
                default: // scatter
                    ForEach(s.points) { p in
                        PointMark(x: .value(spec.xLabel ?? "X", p.x),
                                  y: .value(spec.yLabel ?? "Y", p.y))
                        .foregroundStyle(by: .value("Series", s.name))
                    }
                }
            }
        }
        .chartYScale(domain: spec.beginAtZeroY
            ? .automatic(includesZero: true)
            : .automatic(includesZero: false))
    }

    // MARK: Bubble Chart

    @ViewBuilder
    private var bubbleChart: some View {
        Chart {
            ForEach(spec.series) { s in
                ForEach(s.points) { p in
                    if #available(iOS 17.0, *), let r = p.size {
                        PointMark(
                            x: .value(spec.xLabel ?? "X", p.x),
                            y: .value(spec.yLabel ?? "Y", p.y)
                        )
                        .symbolSize(by: .value("Size", r))
                        .foregroundStyle(by: .value("Series", s.name))
                    } else if let r = p.size {
                        PointMark(
                            x: .value(spec.xLabel ?? "X", p.x),
                            y: .value(spec.yLabel ?? "Y", p.y)
                        )
                        .symbolSize(CGFloat(max(6, min(80, r))))
                        .foregroundStyle(by: .value("Series", s.name))
                    } else {
                        PointMark(
                            x: .value(spec.xLabel ?? "X", p.x),
                            y: .value(spec.yLabel ?? "Y", p.y)
                        )
                        .foregroundStyle(by: .value("Series", s.name))
                    }
                }
            }
        }
        .chartYScale(domain: spec.beginAtZeroY
            ? .automatic(includesZero: true)
            : .automatic(includesZero: false))
    }

    // MARK: Pie Chart

    @ViewBuilder
    private var pieChart: some View {
        let data = pieData(from: spec)
        if #available(iOS 17.0, *) {
            Chart(data) { d in
                SectorMark(
                    angle: .value("Value", d.value),
                    innerRadius: .ratio(0.0),
                    angularInset: 1
                )
                .foregroundStyle(by: .value("Category", d.label))
                .annotation(position: .overlay, alignment: .center) {
                    if d.pct >= 0.08 {
                        Text("\(d.label)\n\(Int(round(d.pct * 100)))%")
                            .font(.system(size: 10, weight: .semibold))
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .chartLegend(.visible)
        } else {
            // iOS 16 fallback: show data as a bar chart
            Chart(data) { d in
                BarMark(
                    x: .value("Category", d.label),
                    y: .value("Value", d.value)
                )
                .foregroundStyle(by: .value("Category", d.label))
            }
        }
    }

    // MARK: Heatmap

    @ViewBuilder
    private var heatmapChart: some View {
        Chart {
            ForEach(spec.series) { s in
                ForEach(s.points) { p in
                    RectangleMark(
                        x: .value("X", p.x),
                        y: .value("Y", s.name),
                        width: .ratio(1.0),
                        height: .ratio(1.0)
                    )
                    .foregroundStyle(by: .value("Value", p.z ?? p.y))
                }
            }
        }
    }

    // MARK: Histogram

    @ViewBuilder
    private var histogramChart: some View {
        let raw = spec.series.first?.points.map { $0.y } ?? []
        let bins = makeBins(raw, targetBins: 10)
        Chart(bins) { b in
            BarMark(x: .value("Bin", b.label), y: .value("Count", b.count))
        }
    }
}

// MARK: - Pie Helpers

private struct PieDatum: Identifiable {
    let id = UUID(); let label: String; let value: Double; let pct: Double
}

private func pieData(from spec: USpec) -> [PieDatum] {
    let pts = spec.series.first?.points ?? []
    let total = max(pts.reduce(0) { $0 + $1.y }, 0.000001)
    return pts.map { PieDatum(label: $0.x, value: $0.y, pct: $0.y / total) }
}

// MARK: - Histogram Helpers

private struct HistogramBin: Identifiable {
    let id = UUID(); let label: String; let count: Int
}

private func makeBins(_ values: [Double], targetBins: Int) -> [HistogramBin] {
    guard let minV = values.min(), let maxV = values.max(), maxV > minV else { return [] }
    let bins = max(targetBins, 1)
    let step = (maxV - minV) / Double(bins)
    var counts = Array(repeating: 0, count: bins)
    for v in values {
        let idx = min(Int((v - minV) / step), bins - 1)
        counts[idx] += 1
    }
    return counts.enumerated().map { i, c in
        HistogramBin(
            label: String(format: "%.1f–%.1f", minV + Double(i) * step, minV + Double(i + 1) * step),
            count: c
        )
    }
}

// MARK: - Highlighted Source View (Headerless)

/// A headerless syntax-highlighted code view using Highlightr.
/// Used inside `ChartPreviewView` and `HTMLPreviewView` when they
/// already provide their own toolbar (to avoid the double header
/// that `DefaultCodeBlockStyle` would produce).
///
/// **Performance:** Shows plain monospaced text immediately (zero stutter),
/// then highlights on a background thread and fades in the colored version.
/// This prevents the scroll hitch that occurs when Highlightr runs
/// synchronously on the main thread for large code blocks.
struct HighlightedSourceView: View {
    let code: String
    let language: String
    /// When true (default), truncates to `maxInlineChars` for performance.
    /// Set to false in fullscreen where the user expects full content.
    var truncate: Bool = true
    /// Maximum height for the scroll container. Defaults to 400 for inline,
    /// pass `.infinity` for fullscreen.
    var maxHeight: CGFloat = 400

    @State private var highlightedCode: AttributedString?
    @State private var lastHighlightedScheme: ColorScheme?
    @Environment(\.colorScheme) private var colorScheme

    private let maxInlineChars = 3000

    private var truncatedCode: String {
        if !truncate || code.count <= maxInlineChars { return code }
        let endIndex = code.index(code.startIndex, offsetBy: maxInlineChars)
        return String(code[..<endIndex])
    }

    var body: some View {
        ScrollView(.vertical) {
            Group {
                if let highlighted = highlightedCode {
                    Text(highlighted)
                } else {
                    Text(truncatedCode)
                        .foregroundStyle(.primary)
                }
            }
            .font(.system(size: 13, design: .monospaced))
            .lineSpacing(4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .textSelection(.enabled)
        }
        .frame(maxHeight: maxHeight)
        .background(Color(.secondarySystemBackground))
        .task(id: colorScheme) {
            guard lastHighlightedScheme != colorScheme else { return }
            await highlightAsync()
        }
    }

    /// Plain monospaced text — Highlightr removed. Code blocks in the main
    /// chat use the library's built-in HighlightSwift-based lazy highlighting.
    /// This source view (chart/HTML "View Source") just shows plain text.
    private func highlightAsync() async {
        // No highlighting — plain monospaced text
        highlightedCode = nil
        lastHighlightedScheme = colorScheme
    }
}
