// functions/index.js
// Fixie AI — Cloud Functions
//
// Trigger: leads/{leadId} document update
// Sends FCM push notifications on three status transitions:
//   available → claimed   "Help is on the way! {proBusinessName} has accepted your request."
//   *         → enRoute   "Pro En Route! {proName} is on the way." (type=dispatch — opens ProServiceCardView)
//   *         → resolved  "Repair Complete! Your project has been moved to your history."
//
// FCM token lookup: tries users/{userId}.fcmToken first, then fcmTokens/{userId}.tokens[] (web portal path).
//
// Deploy: cd functions && npm install && cd .. && firebase deploy --only functions
// Logs:   firebase functions:log

const { onDocumentUpdated, onDocumentCreated } = require("firebase-functions/v2/firestore");
const { initializeApp }     = require("firebase-admin/app");
const { getFirestore }      = require("firebase-admin/firestore");
const { getMessaging }      = require("firebase-admin/messaging");

initializeApp();

// ─────────────────────────────────────────────────────────────────────────────
// Helper: resolve FCM token for a user.
// Tries users/{uid}.fcmToken first (internal), then fcmTokens/{uid}.tokens[] (web portal).
// Returns the best available token string, or null if none found.
// ─────────────────────────────────────────────────────────────────────────────
async function getFCMToken(db, userId) {
  // Primary: users/{uid}.fcmToken
  const userDoc = await db.collection("users").doc(userId).get();
  const primaryToken = userDoc.data()?.fcmToken;
  if (primaryToken) return primaryToken;

  // Fallback: fcmTokens/{uid}.tokens[] (written by the iOS app for the web portal)
  const tokenDoc = await db.collection("fcmTokens").doc(userId).get();
  const tokens = tokenDoc.data()?.tokens;
  if (Array.isArray(tokens) && tokens.length > 0) {
    return tokens[tokens.length - 1]; // most recently appended token
  }

  return null;
}

// ─────────────────────────────────────────────────────────────────────────────
// notifyLeadStatusChange
// ─────────────────────────────────────────────────────────────────────────────
exports.notifyLeadStatusChange = onDocumentUpdated(
  "leads/{leadId}",
  async (event) => {
    const before = event.data.before.data();
    const after  = event.data.after.data();

    if (!before || !after) return;

    const prevStatus = before.status;
    const newStatus  = after.status;
    const leadId     = event.params.leadId;
    const userId     = after.userId;

    if (!userId) {
      console.log("[Fixie] leads doc missing userId — skipping");
      return;
    }

    const device = (after.deviceModel || "").trim() || null;
    const db     = getFirestore();

    // ── rescheduled (rescheduledAt just appeared) ─────────────────────────────
    const prevRescheduledAt = before.rescheduledAt;
    const newRescheduledAt  = after.rescheduledAt;

    if (!prevRescheduledAt && newRescheduledAt) {
      const fcmToken = await getFCMToken(db, userId);
      if (fcmToken) {
        const scheduledTs = after.scheduledTime;
        let scheduledStr = "a new time";
        if (scheduledTs && scheduledTs.toDate) {
          const d = scheduledTs.toDate();
          scheduledStr = d.toLocaleString("en-US", {
            month: "short", day: "numeric",
            hour: "numeric", minute: "2-digit", hour12: true,
          });
        }
        const epochSec = scheduledTs && scheduledTs.toDate
          ? String(Math.round(scheduledTs.toDate().getTime() / 1000))
          : "";
        const rescheduleMsg = {
          token: fcmToken,
          notification: {
            title: "Appointment Rescheduled",
            body:  `Your job has been moved to ${scheduledStr}.`,
          },
          apns: { payload: { aps: { sound: "default", badge: 1 } } },
          data: { leadId, type: "reschedule", scheduledTime: epochSec },
        };
        try {
          const msgId = await getMessaging().send(rescheduleMsg);
          console.log(`[Fixie] ✅ Reschedule notification sent: ${msgId}`);
        } catch (err) {
          console.error(`[Fixie] ⚠️ Reschedule notification failed: ${err.message}`);
        }
      }
    }

    // No status change — nothing more to do
    if (prevStatus === newStatus) return;

    let title       = "";
    let body        = "";
    let dataPayload = { leadId, status: newStatus };

    // ── available → claimed ──────────────────────────────────────────────────
    if (prevStatus === "available" && newStatus === "claimed") {
      const proName = after.proBusinessName || after.proName || "A professional";
      title = "Help is on the way!";
      body  = device
        ? `${proName} has accepted your ${device} repair request.`
        : `${proName} has accepted your repair request.`;

    // ── * → enRoute ──────────────────────────────────────────────────────────
    } else if (newStatus === "enRoute") {
      const proName = after.proName || after.proBusinessName || "Your pro";
      title = "Pro En Route!";
      body  = device
        ? `${proName} is on the way for your ${device}.`
        : `${proName} is on the way.`;

      // Calculate ETA in minutes from estimatedArrival timestamp
      let etaMinutes = "0";
      const etaTs = after.estimatedArrival;
      if (etaTs && etaTs.toDate) {
        const minsAway = Math.round((etaTs.toDate().getTime() - Date.now()) / 60000);
        if (minsAway > 0) etaMinutes = String(minsAway);
      }

      // type="dispatch" tells AppDelegate to post dispatchTappedNotification
      // and open ProServiceCardView for this lead.
      dataPayload = {
        ...dataPayload,
        type:        "dispatch",
        proName:     after.proName || after.proBusinessName || "",
        etaMinutes,
      };

    // ── * → resolved ─────────────────────────────────────────────────────────
    } else if (newStatus === "resolved") {
      title = "Repair Complete!";
      body  = device
        ? `Your ${device} repair is done and has been saved to your history.`
        : "Your repair is complete and has been saved to your history.";

    } else {
      // Other transitions — no notification
      return;
    }

    // Fetch FCM token (tries both paths)
    const fcmToken = await getFCMToken(db, userId);

    if (!fcmToken) {
      console.log(`[Fixie] No FCM token for user ${userId} — skipping notification`);
      return;
    }

    const message = {
      token: fcmToken,
      notification: { title, body },
      apns: {
        payload: {
          aps: {
            sound: "default",
            badge: 1,
          },
        },
      },
      data: dataPayload,
    };

    try {
      const msgId = await getMessaging().send(message);
      console.log(`[Fixie] ✅ Notification sent (${newStatus}): ${msgId}`);
    } catch (err) {
      console.error(`[Fixie] ⚠️ Failed to send notification: ${err.message}`);
    }
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// notifyProHomeownerResolved
// Trigger: leads/{leadId} updated with homeownerResolved: true (first time)
// Sends FCM push to the pro so they know the homeowner confirmed the repair,
// invoice is requested, and any resolution notes from the customer.
// Pro's FCM token is read from contractors/{proId}.fcmToken or
// fcmTokens/{proId}.tokens[] (same two-path lookup used for homeowner).
// ─────────────────────────────────────────────────────────────────────────────
exports.notifyProHomeownerResolved = onDocumentUpdated(
  "leads/{leadId}",
  async (event) => {
    const before = event.data.before.data();
    const after  = event.data.after.data();

    if (!before || !after) return;

    // Only fire once — when homeownerResolved transitions false → true
    if (before.homeownerResolved || !after.homeownerResolved) return;

    const proId  = after.proId;
    const leadId = event.params.leadId;

    if (!proId) {
      console.log("[Fixie] notifyProHomeownerResolved: no proId on lead — skipping");
      return;
    }

    const db     = getFirestore();
    const device = (after.deviceModel || "").trim() || null;
    const notes  = (after.resolutionNotes || "").trim();

    const body = device
      ? `The homeowner confirmed the ${device} repair is complete.${notes ? " Notes: " + notes : ""}`
      : `The homeowner confirmed the repair is complete.${notes ? " Notes: " + notes : ""}`;

    // Resolve pro's FCM token (same two-path strategy as homeowner)
    const proToken = await getFCMToken(db, proId);

    if (!proToken) {
      console.log(`[Fixie] notifyProHomeownerResolved: no FCM token for pro ${proId}`);
      return;
    }

    const message = {
      token: proToken,
      notification: {
        title: "Repair Confirmed by Homeowner ✓",
        body,
      },
      apns: {
        payload: { aps: { sound: "default", badge: 1 } },
      },
      data: {
        leadId,
        type:              "homeowner_resolved",
        invoiceRequested:  "true",
        resolutionNotes:   notes,
      },
    };

    try {
      const msgId = await getMessaging().send(message);
      console.log(`[Fixie] ✅ Pro notified of homeowner resolution: ${msgId}`);
    } catch (err) {
      console.error(`[Fixie] ⚠️ Pro resolution notification failed: ${err.message}`);
    }
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// aggregateReview
// Trigger: new document in contractors/{proId}/reviews/{reviewId}
// Recalculates averageRating (1 decimal) and reviewCount on the parent
// contractor doc every time a new review is written by a customer.
// ─────────────────────────────────────────────────────────────────────────────
exports.aggregateReview = onDocumentCreated(
  "contractors/{proId}/reviews/{reviewId}",
  async (event) => {
    const proId = event.params.proId;
    const db    = getFirestore();

    const reviewsSnap = await db
      .collection("contractors")
      .doc(proId)
      .collection("reviews")
      .get();

    let total = 0;
    let count = 0;

    reviewsSnap.forEach((doc) => {
      const rating = doc.data().rating;
      if (typeof rating === "number" && rating >= 1 && rating <= 5) {
        total += rating;
        count++;
      }
    });

    const averageRating = count > 0
      ? Math.round((total / count) * 10) / 10
      : 0;

    await db.collection("contractors").doc(proId).update({
      averageRating,
      reviewCount: count,
    });

    console.log(
      `[Fixie] ✅ Review aggregated for ${proId}: ${averageRating} (${count} reviews)`
    );
  }
);
