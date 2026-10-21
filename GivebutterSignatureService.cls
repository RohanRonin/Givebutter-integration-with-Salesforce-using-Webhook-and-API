public without sharing class GivebutterSignatureService {

    /**
     * Verifies the Signature header sent by Givebutter.
     *
     * @param receivedSignature Signature header from Givebutter
     * @return true if the signature matches the configured secret
     */
    public static Boolean verifySignature(String receivedSignature) {

        if (String.isBlank(receivedSignature)) {
            return false;
        }

        String expectedSignature = GivebutterSettingsService.getSigningSecret();
        
        return receivedSignature == expectedSignature;
    }


    /**
     * Verifies the signature and throws an exception
     * if the signature is invalid.
     */
    public static void validateSignature(String receivedSignature) {

        if (!verifySignature(receivedSignature)) {

            throw new GivebutterSignatureException(
                'Invalid Givebutter webhook signature.'
            );
        }
    }


    /**
     * Custom exception for signature validation errors.
     */
    public class GivebutterSignatureException extends Exception {}
}