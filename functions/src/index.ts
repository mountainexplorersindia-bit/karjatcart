import { initializeApp } from "firebase-admin/app";
import { getAuth } from "firebase-admin/auth";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { OAuth2Client } from "google-auth-library";

initializeApp();

const GOOGLE_OAUTH_CLIENT_IDS = [
	"1073459309705-46cj9l2r9rekbl7svf1d0ce5qggi1o0j.apps.googleusercontent.com",
	"1073459309705-rmpfv26c8p22donekacd9m7gfqn785m2.apps.googleusercontent.com",
	"1073459309705-gk7lqef837rmojes8jjphqqv0g15uuu3.apps.googleusercontent.com",
];

const GOOGLE_ISSUERS = new Set([
	"accounts.google.com",
	"https://accounts.google.com",
]);

const googleOAuthClient = new OAuth2Client();

type IdentityResolutionResult =
	| { success: true; route: "direct_login"; customToken: string }
	| { success: false; route: "phone_verification" | "not_eligible" };

function isUserNotFound(error: unknown): boolean {
	return (
		typeof error === "object" &&
		error !== null &&
		"code" in error &&
		error.code === "auth/user-not-found"
	);
}

export const resolveGoogleIdentity = onCall(
	{ enforceAppCheck: false },
	async (request): Promise<IdentityResolutionResult> => {
		try {
			const input: unknown = request.data;
			const inputValid =
				typeof input === "object" &&
				input !== null &&
				!Array.isArray(input) &&
				Object.keys(input).length === 1 &&
				"googleIdToken" in input &&
				typeof input.googleIdToken === "string" &&
				input.googleIdToken.trim().length > 0;
			if (!inputValid) {
				throw new HttpsError("invalid-argument", "Invalid sign-in request.");
			}
			const googleIdToken = (input as { googleIdToken: string }).googleIdToken;

			let providerUid: string | undefined;
			let issuer: string | undefined;
			try {
				const ticket = await googleOAuthClient.verifyIdToken({
					idToken: googleIdToken,
					audience: GOOGLE_OAUTH_CLIENT_IDS,
				});
				const payload = ticket.getPayload();
				providerUid = payload?.sub;
				issuer = payload?.iss;
			} catch (_) {
				throw new HttpsError(
					"unauthenticated",
					"Google authentication could not be verified.",
				);
			}

			if (!providerUid || !issuer || !GOOGLE_ISSUERS.has(issuer)) {
				throw new HttpsError(
					"unauthenticated",
					"Google authentication could not be verified.",
				);
			}

			let user;
			try {
				user = await getAuth().getUserByProviderUid(
					"google.com",
					providerUid,
				);
			} catch (error) {
				if (isUserNotFound(error)) {
					return { success: false, route: "phone_verification" };
				}
				throw new HttpsError(
					"internal",
					"Google sign-in could not be completed.",
				);
			}

			const hasMatchingGoogleProvider = user.providerData.some(
				(provider) =>
					provider.providerId === "google.com" &&
					provider.uid === providerUid,
			);
			const phoneNumber = user.phoneNumber?.trim() ?? "";
			const hasMatchingPhoneProvider = user.providerData.some(
				(provider) =>
					provider.providerId === "phone" &&
					provider.uid.trim() === phoneNumber &&
					phoneNumber.length > 0,
			);
			const enabled = !user.disabled;
			if (!enabled || !hasMatchingGoogleProvider || !hasMatchingPhoneProvider) {
				return { success: false, route: "not_eligible" };
			}

			try {
				const customToken = await getAuth().createCustomToken(user.uid);
				return { success: true, route: "direct_login", customToken };
			} catch (_) {
				throw new HttpsError(
					"internal",
					"Google sign-in could not be completed.",
				);
			}
		} catch (error) {
			if (error instanceof HttpsError) throw error;
			throw new HttpsError(
				"internal",
				"Google sign-in could not be completed.",
			);
		}
	},
);