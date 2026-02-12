import SwiftUI
import UIKit

struct TabBarReselectObserver: UIViewControllerRepresentable {
    let onTabTap: (Int, Bool) -> Void

    func makeCoordinator() -> TabBarReselectCoordinator {
        TabBarReselectCoordinator(onTabTap: onTabTap)
    }

    func makeUIViewController(context: Context) -> ObserverViewController {
        let controller = ObserverViewController()
        controller.onAttach = { host in
            context.coordinator.attach(to: host)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: ObserverViewController, context: Context) {
        context.coordinator.onTabTap = onTabTap
        uiViewController.onAttach = { host in
            context.coordinator.attach(to: host)
        }
    }
}

final class ObserverViewController: UIViewController {
    var onAttach: ((UIViewController) -> Void)?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onAttach?(self)
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        onAttach?(self)
    }
}

final class TabBarReselectCoordinator: NSObject, UITabBarControllerDelegate {
    var onTabTap: (Int, Bool) -> Void

    private weak var observedTabBarController: UITabBarController?
    private weak var previousDelegate: UITabBarControllerDelegate?
    private var lastSelectedIndex: Int?

    init(onTabTap: @escaping (Int, Bool) -> Void) {
        self.onTabTap = onTabTap
    }

    func attach(to viewController: UIViewController) {
        guard let tabBarController = findTabBarController(from: viewController) else {
            return
        }

        if observedTabBarController !== tabBarController {
            previousDelegate = (tabBarController.delegate === self) ? nil : tabBarController.delegate
            observedTabBarController = tabBarController
            tabBarController.delegate = self
            lastSelectedIndex = tabBarController.selectedIndex
        }
    }

    private func findTabBarController(from viewController: UIViewController) -> UITabBarController? {
        if let tabBarController = viewController.tabBarController {
            return tabBarController
        }

        var current = viewController.parent
        while let controller = current {
            if let tabBarController = controller as? UITabBarController {
                return tabBarController
            }
            current = controller.parent
        }

        return nil
    }

    func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
        previousDelegate?.tabBarController?(tabBarController, shouldSelect: viewController) ?? true
    }

    func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        let selectedIndex = tabBarController.selectedIndex
        let isReselect = (lastSelectedIndex == selectedIndex)
        onTabTap(selectedIndex, isReselect)
        lastSelectedIndex = selectedIndex

        previousDelegate?.tabBarController?(tabBarController, didSelect: viewController)
    }
}
