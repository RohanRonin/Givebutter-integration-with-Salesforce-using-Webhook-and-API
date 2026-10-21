public without sharing class GivebutterSettingsService {

    /**
     * Get the Givebutter configuration
     * from Custom Metadata.
     */
    public static Givebutter_Settings__mdt getSettings() {

        Givebutter_Settings__mdt settings = Givebutter_Settings__mdt.getInstance('Default');

        if (settings == null) {
            throw new GivebutterSettingsException('Givebutter Settings Custom Metadata record "Default" was not found.');
        }

        return settings;
    }


    /**
     * Get the Givebutter webhook signing secret.
     */
    public static String getSigningSecret() {

        Givebutter_Settings__mdt settings = getSettings();

        if (String.isBlank(settings.Signing_Secret__c)) {
            throw new GivebutterSettingsException(
                'Givebutter Signing Secret is not configured.'
            );
        }

        return settings.Signing_Secret__c;
    }


    /**
     * Custom exception for Givebutter configuration errors.
     */
    public class GivebutterSettingsException extends Exception {}
}