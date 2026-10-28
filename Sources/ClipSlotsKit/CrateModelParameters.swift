import Foundation

/// Shared model boundary for canvas, batch generation and the provider adapter.
/// A changed capability fails before submission instead of quietly using defaults.
public enum CrateModelParameters {
    private static func reject(_ message: String) throws {
        throw CrateRequestError.invalidModelParameter(message)
    }
    private static func option(_ value: String, name: String, supported: Bool,
                               options: [CrateModelCatalog.RatioOption]) throws {
        guard !value.isEmpty else { return }
        guard supported else { try reject("模型未发布 \(name) 参数"); return }
        if !options.isEmpty && !options.contains(where: { $0.value == value }) {
            try reject("\(name) 已不在模型参数表中：\(value)，请刷新并重新选择")
        }
    }
    public static func image(_ request: CrateImageRequest, model: CrateModelCatalog.ModelInfo,
                             resolveDimensions: Bool = false) throws -> CrateImageRequest {
        guard model.enabled, model.isImageGenerator, model.id == request.model else {
            try reject("所选图片模型已不可用，请刷新模型目录"); return request
        }
        var result = request
        if resolveDimensions, CanvasImageConfiguration.supportsSplit(model),
           request.width == nil || model.supportsRatio {
            let selection = CanvasImageConfiguration.selection(ratio: request.ratio, resolution: request.resolution ?? "")
            guard let dimensions = CanvasImageConfiguration.dimensions(ratio: selection.ratio,
                                                                       quality: selection.quality, model: model) else {
                try reject("所选尺寸超出模型当前的像素或比例范围"); return request
            }
            result.width = dimensions.width; result.height = dimensions.height
            result.ratio = model.supportsRatio ? selection.ratio : ""
            result.resolution = selection.quality
        }
        try option(result.ratio, name: "ratio", supported: model.supportsRatio, options: model.ratioOptions)
        if result.width != nil || result.height != nil {
            guard model.parameterNames.isSuperset(of: ["width", "height"]),
                  let width = result.width, let height = result.height,
                  model.imageDimensionLimits.allows(width: width, height: height) else {
                try reject("图片宽高超出模型当前的尺寸范围"); return request
            }
        } else {
            try option(result.resolution ?? "", name: "resolution", supported: model.supportsResolution,
                       options: model.resolutionOptions)
        }
        if !result.imagePaths.isEmpty, !model.acceptsImageInput { try reject("该模型不支持参考图片") }
        if model.requiresImageInput, result.imagePaths.isEmpty { throw CrateRequestError.missingRequiredImage(model: model.id) }
        if let max = model.imageInputMaxCount, result.imagePaths.count > max { try reject("参考图片超过模型上限 \(max)") }
        return result
    }
    public static func video(_ request: CrateVideoRequest,
                             model: CrateModelCatalog.ModelInfo) throws -> CrateVideoRequest {
        guard model.enabled, model.isVideoGenerator, model.id == request.model else {
            try reject("所选视频模型已不可用，请刷新模型目录"); return request
        }
        var result = request
        if !model.supportsFirstFrame, model.acceptsVideoImageInput {
            let images = request.imagePaths + [request.firstFramePath, request.lastFramePath].compactMap { $0 }
                + request.referenceImagePaths
            result.imagePaths = Array(NSOrderedSet(array: images)) as? [String] ?? images
            result.firstFramePath = nil; result.lastFramePath = nil; result.referenceImagePaths = []
        }
        let images = result.imagePaths + [result.firstFramePath, result.lastFramePath].compactMap { $0 }
            + result.referenceImagePaths
        try option(result.ratio, name: "ratio", supported: model.supportsRatio, options: model.ratioOptions)
        try option(result.resolution, name: "resolution", supported: model.supportsResolution, options: model.resolutionOptions)
        if let duration = result.duration {
            if !model.supportsDuration || model.durationSpec.map({ !$0.allows(duration) }) == true {
                try reject("时长超出模型当前的可选范围")
            }
        }
        if result.generateAudio != nil, !model.supportsAudio { try reject("该模型未发布配音参数") }
        if !images.isEmpty, !model.acceptsVideoImageInput { try reject("该模型不支持输入图片") }
        if model.requiresImageInput, images.isEmpty { throw CrateRequestError.missingRequiredImage(model: model.id) }
        if !images.isEmpty, model.textOnlyResolutions.contains(result.resolution) {
            try reject("\(result.resolution) 仅支持文生视频，请选择其他分辨率")
        }
        if let requiredDuration = model.resolutionDurations[result.resolution],
           (result.duration ?? model.durationDefault) != requiredDuration {
            try reject("\(result.resolution) 要求 \(requiredDuration) 秒时长")
        }
        if result.lastFramePath != nil && (result.firstFramePath == nil || !model.supportsLastFrame) {
            try reject("尾帧需要该模型支持尾帧，并同时指定首帧")
        }
        if result.referenceImagePaths.count > model.referenceImageMaxCount {
            try reject("参考图片超过模型上限 \(model.referenceImageMaxCount)")
        }
        if model.framesExcludeReferences, !result.referenceImagePaths.isEmpty,
           result.firstFramePath != nil || result.lastFramePath != nil {
            try reject("该模型的首尾帧与参考图不能同时使用")
        }
        if let max = model.imageInputMaxCount, images.count > max { try reject("图片输入超过模型上限 \(max)") }
        return result
    }
}
