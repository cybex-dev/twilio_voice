const { AccessToken } = require('twilio').jwt;
const functions = require('firebase-functions');

const { VoiceGrant } = AccessToken;

exports.accessToken = functions.https.onCall((payload, context) => {
  const userId = helpers.checkAuth(context.auth);
  console.log('creating access token for ', userId);
  //configuration using firebase environment variables
  const twilioConfig = functions.config().twilio;

  const accountSid = twilioConfig.account_sid;
  const apiKey = twilioConfig.api_key;
  const apiSecret = twilioConfig.api_key_secret;

  // Used specifically for creating Voice tokens
  let pushCredSid;
  if (payload.platform === 'iOS') {
    console.log('creating access token for iOS');
    pushCredSid = payload.production ? twilioConfig.apple_push_sid_release
      : (twilioConfig.apple_push_sid_debug || twilioConfig.apple_push_sid_release);
  } else {
    console.log('creating access token for Android');
    pushCredSid = twilioConfig.android_push_sid;
  }
  const outgoingApplicationSid = twilioConfig.app_sid;
  // Create an access token which we will sign and return to the client,
  // containing the grant we just created
  const voiceGrant = new VoiceGrant({
    outgoingApplicationSid,
    pushCredentialSid: pushCredSid,
  });

  // Create an access token which we will sign and return to the client,
  // containing the grant we just created
  const token = new AccessToken(accountSid, apiKey, apiSecret);
  token.addGrant(voiceGrant);
  token.identity = userId;
  console.log(`Token:${token.toJwt()}`);
  return token.toJwt();
});
