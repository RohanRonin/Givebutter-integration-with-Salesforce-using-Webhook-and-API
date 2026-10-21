public class GivebutterCampaignApiTest {
    
    public static void testCampaign(String campaignId) {
        HttpRequest req = new HttpRequest();
        
        req.setEndpoint(
            'callout:Givebutter_API/v1/campaigns/' +
            EncodingUtil.urlEncode(campaignId, 'UTF-8')
        );
        req.setMethod('GET');
        req.setHeader('Accept', 'application/json');
        req.setTimeout(30000);
        
        try {
            Http http = new Http();
            HttpResponse res = http.send(req);
            
            System.debug('===== GIVEBUTTER CAMPAIGN API TEST =====');
            System.debug('Campaign ID: ' + campaignId);
            System.debug('HTTP Status Code: ' + res.getStatusCode());
            System.debug('HTTP Status: ' + res.getStatus());
            System.debug('Response Body: ' + res.getBody());
            
            if (res.getStatusCode() >= 200 &&
                res.getStatusCode() < 300) {
                    
                    System.debug(
                        'SUCCESS: Campaign API is accessible.'
                    );
                } else {
                    System.debug(
                        'FAILED: Campaign API returned HTTP ' +
                        res.getStatusCode()
                    );
                }
            
        } catch (Exception e) {
            System.debug('CAMPAIGN API ERROR: ' + e.getMessage());
            System.debug('STACK TRACE: ' + e.getStackTraceString());
        }
    }
    
    public static void inspectCampaignFields(String campaignId) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(
            'callout:Givebutter_API/v1/campaigns/' +
            EncodingUtil.urlEncode(campaignId, 'UTF-8')
        );
        req.setMethod('GET');
        req.setHeader('Accept', 'application/json');
        
        HttpResponse res = new Http().send(req);
        
        System.debug('HTTP STATUS: ' + res.getStatusCode());
        
        if (res.getStatusCode() == 200) {
            Map<String, Object> campaign =
                (Map<String, Object>) JSON.deserializeUntyped(
                    res.getBody()
                );
            
            for (String fieldName : campaign.keySet()) {
                System.debug(
                    'CAMPAIGN FIELD: ' + fieldName +
                    ' = ' + JSON.serialize(campaign.get(fieldName))
                );
            }
        } else {
            System.debug('ERROR BODY: ' + res.getBody());
        }
    }
    
}