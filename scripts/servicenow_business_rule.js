gs.info(
    'AWS DevOps Agent Business Rule fired for ' +
    current.number
);

(function executeRule(current, previous) {

    var LOG_PREFIX = 'AWS DevOps Agent: ';

    try {

        var webhookUrl = gs.getProperty(
            'aws.devopsagent.webhook.url'
        );

        var webhookSecret = gs.getProperty(
            'aws.devopsagent.webhook.secret'
        );

        if (!webhookUrl || !webhookSecret) {

            gs.error(
                LOG_PREFIX +
                'Webhook URL or secret is missing'
            );

            return;
        }

        var timestamp = new Date().toISOString();

        var payloadObject = {

            eventType: 'incident',

            incidentId: current.number.toString(),

            action: 'created',

            priority: mapPriority(
                current.priority
            ),

            title: getValue(
                current.short_description,
                current.number.toString()
            ),

            description: getValue(
                current.description,
                getValue(
                    current.short_description,
                    current.number.toString()
                )
            ),

            timestamp: timestamp,

            service: 'ServiceNow',

            data: {

                sysId:
                    current.sys_id.toString(),

                incidentNumber:
                    current.number.toString(),

                incidentUrl:
                    gs.getProperty(
                        'glide.servlet.uri'
                    ) +
                    'incident.do?sys_id=' +
                    current.sys_id,

                assignmentGroup:
                    getDisplay(
                        current.assignment_group
                    ),

                assignedTo:
                    getDisplay(
                        current.assigned_to
                    ),

                caller:
                    getDisplay(
                        current.caller_id
                    ),

                category:
                    getValue(
                        current.category,
                        ''
                    ),

                subcategory:
                    getValue(
                        current.subcategory,
                        ''
                    ),

                impact:
                    getValue(
                        current.impact,
                        ''
                    ),

                urgency:
                    getValue(
                        current.urgency,
                        ''
                    )
            }
        };

        /*
         * IMPORTANT:
         * Use the exact same payload string
         * for signing and transmission.
         */
        var payloadString =
            JSON.stringify(payloadObject);

        var stringToSign =
            timestamp + ':' + payloadString;

        var encodedSecret =
            GlideStringUtil.base64Encode(
                webhookSecret
            );

        var mac =
            new GlideCertificateEncryption();

        var signature =
            mac.generateMac(
                encodedSecret,
                'HmacSHA256',
                stringToSign
            );

        if (!signature) {

            gs.error(
                LOG_PREFIX +
                'HMAC generation failed'
            );

            return;
        }

        var request =
            new sn_ws.RESTMessageV2();

        request.setEndpoint(
            webhookUrl
        );

        request.setHttpMethod(
            'POST'
        );

        request.setHttpTimeout(
            30000
        );

        request.setRequestHeader(
            'Content-Type',
            'application/json'
        );

        request.setRequestHeader(
            'x-amzn-event-timestamp',
            timestamp
        );

        request.setRequestHeader(
            'x-amzn-event-signature',
            signature
        );

        request.setRequestBody(
            payloadString
        );

        var response =
            request.execute();

        var statusCode =
            response.getStatusCode();

        if (
            statusCode >= 200 &&
            statusCode < 300
        ) {

            gs.info(
                LOG_PREFIX +
                'Webhook sent successfully. Ticket=' +
                current.number +
                ', Status=' +
                statusCode
            );

        } else {

            gs.error(
                LOG_PREFIX +
                'Webhook failed. Ticket=' +
                current.number +
                ', Status=' +
                statusCode +
                ', Response=' +
                response.getBody()
            );
        }

    } catch (error) {

        gs.error(
            LOG_PREFIX +
            'Unexpected Error: ' +
            error
        );
    }

    function mapPriority(priorityField) {

        var priority =
            priorityField.toString();

        switch (priority) {

            case '1':
                return 'CRITICAL';

            case '2':
                return 'HIGH';

            case '3':
                return 'MEDIUM';

            case '4':
                return 'LOW';

            case '5':
                return 'MINIMAL';

            default:
                return 'MEDIUM';
        }
    }

    function getValue(
        field,
        defaultValue
    ) {

        if (
            !field ||
            gs.nil(field)
        ) {
            return defaultValue;
        }

        return field.toString();
    }

    function getDisplay(field) {

        if (
            !field ||
            gs.nil(field)
        ) {
            return '';
        }

        try {
            return field.getDisplayValue();
        } catch (e) {
            return field.toString();
        }
    }

})(current, previous);