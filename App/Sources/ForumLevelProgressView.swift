import SwiftUI

struct ForumLevelProgressPresentation: Equatable, Sendable {
  let levelTitle: String
  let experienceText: String
  let fractionCompleted: Double
  let accessibilityValue: String

  init(progress: ForumLevelProgressData) {
    levelTitle = "LV\(progress.level) · \(progress.levelName)"
    experienceText =
      "经验 \(progress.currentExperience.formatted()) / "
      + progress.targetExperience.formatted()
    fractionCompleted = progress.fractionCompleted
    let percentage = Int((fractionCompleted * 100).rounded())
    accessibilityValue =
      "等级 \(progress.level)，\(progress.levelName)，当前经验 "
      + "\(progress.currentExperience.formatted())，升级经验 "
      + "\(progress.targetExperience.formatted())，完成 \(percentage)%"
  }
}

struct ForumLevelProgressView: View {
  let presentation: ForumLevelProgressPresentation
  let showsCheckedInMark: Bool

  init(
    progress: ForumLevelProgressData,
    showsCheckedInMark: Bool = false
  ) {
    presentation = ForumLevelProgressPresentation(progress: progress)
    self.showsCheckedInMark = showsCheckedInMark
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 4) {
        Text(presentation.levelTitle)
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)

        if showsCheckedInMark {
          ForumCheckedInMark()
            .accessibilityHidden(true)
        }
      }

      HStack(spacing: 8) {
        Text(presentation.experienceText)
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .minimumScaleFactor(0.75)
          .layoutPriority(1)

        ProgressView(value: presentation.fractionCompleted)
          .frame(minWidth: 44, maxWidth: .infinity)
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("贴吧等级进度")
    .accessibilityValue(
      showsCheckedInMark
        ? "\(presentation.accessibilityValue)，今日已签到"
        : presentation.accessibilityValue
    )
  }
}

struct ForumCheckedInMark: View {
  var body: some View {
    Image(systemName: "checkmark")
      .font(.system(size: 12, weight: .bold))
      .foregroundStyle(.secondary)
      .frame(width: 14, height: 14)
      .accessibilityLabel("今日已签到")
  }
}
