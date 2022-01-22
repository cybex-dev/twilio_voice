package com.twilio.twilio_voice;

import android.content.Context;
import android.content.SharedPreferences;
import android.preference.PreferenceManager;

public class PreferenceSingleton {

    public static final String TwilioPreferences = "com.twilio.twilio_voicePreferences";
    private static PreferenceSingleton mInstance;
    private Context mContext;
    //
    private SharedPreferences pSharedPref;

    private PreferenceSingleton(){ }

    public static PreferenceSingleton getInstance(){
        if (mInstance == null) mInstance = new PreferenceSingleton();
        return mInstance;
    }

    public void Initialize(Context ctx){
        mContext = ctx;
        pSharedPref = PreferenceManager.getDefaultSharedPreferences(mContext);
    }
}