//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import Foundation
import SignalServiceKit
import SignalMessaging
import PromiseKit

#if DEBUG

class DebugUINotifications: DebugUIPage {

    // MARK: Overrides

    override func name() -> String {
        return "Notifications"
    }

    override func section(thread: TSThread?) -> OWSTableSection? {
        guard let thread = thread else {
            owsFailDebug("Notifications must specify thread.")
            return nil
        }

        var sectionItems: [OWSTableItem] = []

        if let contactThread = thread as? TSContactThread {
            sectionItems += [
                OWSTableItem(title: "All Notifications in Sequence") { [weak self] in
                    _ = self?.notifyForEverythingInSequence(contactThread: contactThread)
                },
                OWSTableItem(title: "Incoming Call") { [weak self] in
                    _ = self?.notifyForIncomingCall(thread: contactThread)
                },
                OWSTableItem(title: "Call Missed") { [weak self] in
                    _ = self?.notifyForMissedCall(thread: contactThread)
                },
                OWSTableItem(title: "Call Rejected: New Safety Number") { [weak self] in
                    _ = self?.notifyForMissedCallBecauseOfNewIdentity(thread: contactThread)
                },
                OWSTableItem(title: "Call Rejected: No Longer Verified") { [weak self] in
                    _ = self?.notifyForMissedCallBecauseOfNoLongerVerifiedIdentity(thread: contactThread)
                }
            ]
        }

        sectionItems += [
            OWSTableItem(title: "Last Incoming Message") { [weak self] in
                _ = self?.notifyForIncomingMessage(thread: thread)
            },

            OWSTableItem(title: "Notify For Error Message") { [weak self] in
                _ = self?.notifyForErrorMessage(thread: thread)
            },

            OWSTableItem(title: "Notify For Threadless Error Message") { [weak self] in
                _ = self?.notifyUserForThreadlessErrorMessage()
            },

            OWSTableItem(title: "Notify of New Signal Users") { [weak self] in
                _ = self?.notifyOfNewUsers()
            }

        ]

        return OWSTableSection(title: "Notifications have delay: \(kNotificationDelay)s", items: sectionItems)
    }

    // MARK: Helpers

    // After enqueing the notification you may want to background the app or lock the screen before it triggers, so
    // we give a little delay.
    let kNotificationDelay: TimeInterval = 5

    func delayedNotificationDispatch(block: @escaping () -> Void) -> Guarantee<Void> {
        Logger.info("⚠️ will present notification after \(kNotificationDelay) second delay")

        // Notifications won't sound if the app is suspended.
        let taskIdentifier = UIApplication.shared.beginBackgroundTask(expirationHandler: nil)

        return after(seconds: kNotificationDelay).done {
            block()
        }.then {
            after(seconds: 2.0)
        }.done {
            // We don't want to endBackgroundTask until *after* the notifications manager is done,
            // but it dispatches async without a completion handler, so we just wait a while extra.
            // This is fragile, but it's only for debug UI.
            UIApplication.shared.endBackgroundTask(taskIdentifier)
        }
    }

    func delayedNotificationDispatchWithFakeCall(thread: TSContactThread, callBlock: @escaping (IndividualCall) -> Void) -> Guarantee<Void> {
        let call = SignalCall.incomingIndividualCall(
            localId: UUID(),
            remoteAddress: thread.contactAddress,
            sentAtTimestamp: Date.ows_millisecondTimestamp(),
            offerMediaType: .audio
        )

        return delayedNotificationDispatch {
            callBlock(call.individualCall)
        }
    }

    // MARK: Notification Methods

    func notifyForEverythingInSequence(contactThread: TSContactThread) -> Guarantee<Void> {
        let taskIdentifier = UIApplication.shared.beginBackgroundTask(expirationHandler: nil)

        return firstly {
            self.notifyForIncomingCall(thread: contactThread)
        }.then {
            self.notifyForMissedCall(thread: contactThread)
        }.then {
            self.notifyForMissedCallBecauseOfNewIdentity(thread: contactThread)
        }.then {
            self.notifyForMissedCallBecauseOfNoLongerVerifiedIdentity(thread: contactThread)
        }.then {
            self.notifyForIncomingMessage(thread: contactThread)
        }.then {
            self.notifyForErrorMessage(thread: contactThread)
        }.then {
            self.notifyUserForThreadlessErrorMessage()
        }.then {
            self.notifyOfNewUsers()
        }.done {
            UIApplication.shared.endBackgroundTask(taskIdentifier)
        }
    }

    func notifyForIncomingCall(thread: TSContactThread) -> Guarantee<Void> {
        return delayedNotificationDispatchWithFakeCall(thread: thread) { call in
            let callerName = self.contactsManager.displayName(for: thread.contactAddress)
            self.notificationPresenter.presentIncomingCall(call, callerName: callerName)
        }
    }

    func notifyForMissedCall(thread: TSContactThread) -> Guarantee<Void> {
        return delayedNotificationDispatchWithFakeCall(thread: thread) { call in
            let callerName = self.contactsManager.displayName(for: thread.contactAddress)
            self.notificationPresenter.presentMissedCall(call, callerName: callerName)
        }
    }

    func notifyForMissedCallBecauseOfNewIdentity(thread: TSContactThread) -> Guarantee<Void> {
        return delayedNotificationDispatchWithFakeCall(thread: thread) { call in
            let callerName = self.contactsManager.displayName(for: thread.contactAddress)
            self.notificationPresenter.presentMissedCallBecauseOfNewIdentity(call: call, callerName: callerName)
        }
    }

    func notifyForMissedCallBecauseOfNoLongerVerifiedIdentity(thread: TSContactThread) -> Guarantee<Void> {
        return delayedNotificationDispatchWithFakeCall(thread: thread) { call in
            let callerName = self.contactsManager.displayName(for: thread.contactAddress)
            self.notificationPresenter.presentMissedCallBecauseOfNoLongerVerifiedIdentity(call: call, callerName: callerName)
        }
    }

    func notifyForIncomingMessage(thread: TSThread) -> Guarantee<Void> {
        return delayedNotificationDispatch {
            self.databaseStorage.write { transaction in
                let factory = IncomingMessageFactory()
                factory.threadCreator = { _ in return thread }
                let incomingMessage = factory.create(transaction: transaction)

                self.notificationPresenter.notifyUser(for: incomingMessage,
                                                      thread: thread,
                                                      transaction: transaction)
            }
        }
    }

    func notifyForErrorMessage(thread: TSThread) -> Guarantee<Void> {
        return delayedNotificationDispatch {
            let builder = TSErrorMessageBuilder(thread: thread, errorType: .invalidMessage)
            let errorMessage = TSErrorMessage(errorMessageWithBuilder: builder)

            self.databaseStorage.write { transaction in
                self.notificationPresenter.notifyUser(for: errorMessage, thread: thread, transaction: transaction)
            }
        }
    }

    func notifyUserForThreadlessErrorMessage() -> Guarantee<Void> {
        return delayedNotificationDispatch {
            self.databaseStorage.write { transaction in
                let errorMessage = ThreadlessErrorMessage.corruptedMessageInUnknownThread()
                self.notificationPresenter.notifyUser(for: errorMessage,
                                                      transaction: transaction)
            }
        }
    }

    func notifyOfNewUsers() -> Guarantee<Void> {
        return delayedNotificationDispatch {
            let recipients: Set<SignalRecipient> = self.databaseStorage.read { transaction in
                let allRecipients = SignalRecipient.anyFetchAll(transaction: transaction)
                let activeRecipients = allRecipients.filter { recipient in
                    guard recipient.devices.count > 0 else {
                        return false
                    }

                    guard !recipient.address.isLocalAddress else {
                        return false
                    }

                    return true
                }

                return Set(activeRecipients)
            }

            NewAccountDiscovery.shared.discovered(newRecipients: recipients, forNewThreadsOnly: false)
        }
    }
}

#endif
