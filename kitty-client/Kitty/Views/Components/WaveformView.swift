import SwiftUI

/// 音频波形可视化组件
/// 根据 audioLevel 显示动态波形效果
struct WaveformView: View {
    let audioLevel: Float
    let isListening: Bool
    let barCount: Int
    let maxHeight: CGFloat

    init(
        audioLevel: Float,
        isListening: Bool = true,
        barCount: Int = 5,
        maxHeight: CGFloat = 40
    ) {
        self.audioLevel = audioLevel
        self.isListening = isListening
        self.barCount = barCount
        self.maxHeight = maxHeight
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(barColor(for: index))
                    .frame(width: 4, height: barHeight(for: index))
            }
        }
        .opacity(isListening ? 1 : 0.3)
    }

    private func barHeight(for index: Int) -> CGFloat {
        if !isListening {
            return maxHeight * 0.3
        }

        // 根据位置计算波动因子，中心条最高
        let centerFactor = 1 - abs(Float(index) - Float(barCount - 1) / 2) / Float(barCount)
        // 结合 audioLevel 和位置因子
        let heightFactor = audioLevel * (0.5 + centerFactor * 0.5)

        return max(maxHeight * 0.2, maxHeight * CGFloat(heightFactor))
    }

    private func barColor(for index: Int) -> Color {
        if !isListening {
            return .gray
        }

        // 根据高度变化颜色
        let intensity = audioLevel
        if intensity > 0.7 {
            return .green.opacity(0.9)
        } else if intensity > 0.4 {
            return .green.opacity(0.7)
        } else {
            return .green.opacity(0.5)
        }
    }
}

/// 更高级的波形视图，带动画效果
struct AnimatedWaveformView: View {
    let audioLevel: Float
    let isListening: Bool

    @State private var animationOffset: Float = 0
    @State private var animationTimer: Timer?

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<7, id: \.self) { index in
                Capsule()
                    .fill(isListening ? Color.green : Color.gray)
                    .frame(width: 3, height: heightForBar(index))
                    .opacity(opacityForBar(index))
            }
        }
        .onAppear {
            if isListening {
                startAnimation()
            }
        }
        .onDisappear {
            stopAnimation()
        }
        .onChange(of: isListening) { newValue in
            if newValue {
                startAnimation()
            } else {
                stopAnimation()
            }
        }
    }

    private func heightForBar(_ index: Int) -> CGFloat {
        if !isListening {
            return 8
        }

        let baseHeight = CGFloat(audioLevel) * 30
        let waveFactor = sin(animationOffset + Float(index) * 0.5) * 0.3 + 0.7
        return max(8, baseHeight * CGFloat(waveFactor))
    }

    private func opacityForBar(_ index: Int) -> Double {
        if !isListening {
            return 0.3
        }
        return 0.5 + Double(audioLevel) * 0.5
    }

    private func startAnimation() {
        animationTimer?.invalidate()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            animationOffset += 0.2
        }
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }
}

#Preview {
    VStack(spacing: 20) {
        WaveformView(audioLevel: 0.8, isListening: true)
        WaveformView(audioLevel: 0.3, isListening: true)
        WaveformView(audioLevel: 0.0, isListening: false)
        AnimatedWaveformView(audioLevel: 0.5, isListening: true)
    }
    .padding()
}