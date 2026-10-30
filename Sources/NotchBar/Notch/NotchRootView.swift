import SwiftUI

struct NotchRootView: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var media: MediaController
    @ObservedObject var usage: ClaudeUsageStore
    @ObservedObject var timer: TimerModel

    var body: some View {
        VStack(spacing: 0) {
            notch
            Spacer(minLength: 0)
        }
        .frame(width: NotchController.canvas.width, height: NotchController.canvas.height, alignment: .top)
        .preferredColorScheme(.dark)
    }

    private var notch: some View {
        let size = vm.size
        return ZStack(alignment: .top) {
            if vm.isExpanded {
                ExpandedNotch(vm: vm, media: media, usage: usage, timer: timer)
                    .frame(width: vm.expandedSize.width, height: vm.expandedSize.height, alignment: .top)
                    .transition(.notchContent)
            } else {
                CollapsedNotch(vm: vm, media: media, usage: usage, timer: timer)
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .transition(.notchContent)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(Color.black)
        .clipShape(NotchShape(topRadius: vm.topRadius, bottomRadius: vm.bottomRadius))
        .shadow(color: .black.opacity(vm.isExpanded || vm.banner != nil ? 0.55 : 0), radius: 16, y: 8)
        .contentShape(NotchShape(topRadius: vm.topRadius, bottomRadius: vm.bottomRadius))
        .offset(x: vm.shapeOffset)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: vm.leftWing)
    }
}
