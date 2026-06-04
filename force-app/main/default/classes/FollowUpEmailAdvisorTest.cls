@isTest
private class FollowUpEmailAdvisorTest {

    @TestSetup
    static void makeData() {
        Account acc = new Account(Name = 'フォロー対象取引先');
        insert acc;

        Contact con = new Contact(
            LastName  = '山田',
            FirstName = '太郎',
            AccountId = acc.Id
        );
        insert con;

        Date today = Date.today();

        // フォローアップ対象：未完了・今後2週間以内のEventなし
        Opportunity opp = new Opportunity(
            Name      = 'フォロー商談A',
            StageName = 'Prospecting',
            CloseDate = today.addDays(20),
            AccountId = acc.Id
        );
        insert opp;

        // 主取引先責任者として関連付け
        OpportunityContactRole role = new OpportunityContactRole(
            OpportunityId = opp.Id,
            ContactId     = con.Id,
            IsPrimary     = true,
            Role          = 'Decision Maker'
        );
        insert role;

        // 完了済みタスク（直近活動）
        Task doneTask = new Task(
            Subject      = '初回ヒアリング',
            Status       = 'Completed',
            Priority     = 'Normal',
            ActivityDate = today.addDays(-5),
            WhatId       = opp.Id,
            Description  = 'ニーズ確認済み'
        );
        insert doneTask;

        // 過去のイベント（直近のやり取りとして取得される）
        DateTime pastStart = DateTime.now().addDays(-3);
        Event pastEvent = new Event(
            Subject           = '提案打ち合わせ',
            StartDateTime     = pastStart,
            DurationInMinutes = 60,
            WhatId            = opp.Id,
            Description       = '提案内容を説明'
        );
        insert pastEvent;

        // 商談に紐づくメール（送信・受信）
        EmailMessage emIn = new EmailMessage(
            Subject     = 'ご検討状況について',
            FromName    = '山田 太郎',
            FromAddress = 'yamada@example.com',
            Incoming    = true,
            Status      = '0',
            MessageDate = DateTime.now().addDays(-2),
            RelatedToId = opp.Id,
            TextBody    = '社内で検討しております。'
        );
        EmailMessage emOut = new EmailMessage(
            Subject     = '資料送付の件',
            FromName    = 'テスト担当',
            FromAddress = 'sales@example.com',
            Incoming    = false,
            Status      = '3',
            MessageDate = DateTime.now().addDays(-4),
            RelatedToId = opp.Id,
            TextBody    = '資料をお送りします。'
        );
        insert new List<EmailMessage>{ emIn, emOut };
    }

    @isTest
    static void testGetFollowUpTargets_default() {
        FollowUpEmailAdvisor.ActionInput inp = new FollowUpEmailAdvisor.ActionInput();

        Test.startTest();
        List<FollowUpEmailAdvisor.ActionOutput> outs =
            FollowUpEmailAdvisor.getFollowUpTargets(
                new List<FollowUpEmailAdvisor.ActionInput>{ inp });
        Test.stopTest();

        System.assertEquals(1, outs.size(), '出力は1件であるべき');
        FollowUpEmailAdvisor.ActionOutput out = outs[0];

        System.assert(out.totalCount >= 1, 'フォロー対象商談が取得されるべき');
        System.assertNotEquals(null, out.opportunityJson, 'JSONが返却されるべき');

        List<Object> opps =
            (List<Object>) JSON.deserializeUntyped(out.opportunityJson);
        System.assertEquals(out.totalCount, opps.size(),
            'totalCountとJSON件数が一致するべき');

        Map<String, Object> first = (Map<String, Object>) opps[0];
        System.assertEquals('フォロー商談A', (String) first.get('opportunityName'),
            '商談名が一致するべき');
        System.assertEquals('山田', (String) first.get('contactName'),
            '主取引先責任者の姓が取得されるべき');

        // 直近のやり取り（活動・メール）が収集されている
        List<Object> activities = (List<Object>) first.get('recentActivities');
        List<Object> emails     = (List<Object>) first.get('recentEmails');
        System.assert(!activities.isEmpty(), '直近活動が含まれるべき');
        System.assert(!emails.isEmpty(), '直近メールが含まれるべき');
    }

    @isTest
    static void testGetFollowUpTargets_nameFilter() {
        FollowUpEmailAdvisor.ActionInput inp = new FollowUpEmailAdvisor.ActionInput();
        inp.opportunityName = 'フォロー';   // 部分一致
        inp.userId = UserInfo.getUserId();

        Test.startTest();
        List<FollowUpEmailAdvisor.ActionOutput> outs =
            FollowUpEmailAdvisor.getFollowUpTargets(
                new List<FollowUpEmailAdvisor.ActionInput>{ inp });
        Test.stopTest();

        System.assert(outs[0].totalCount >= 1, '部分一致で商談が取得されるべき');
    }

    @isTest
    static void testGetFollowUpTargets_excludedByFutureEvent() {
        // 今後2週間以内にEventがある商談は対象外になることを確認
        Opportunity opp = [SELECT Id FROM Opportunity WHERE Name = 'フォロー商談A' LIMIT 1];
        Event futureEvent = new Event(
            Subject           = '次回打ち合わせ',
            StartDateTime     = DateTime.now().addDays(3),
            DurationInMinutes = 60,
            WhatId            = opp.Id
        );
        insert futureEvent;

        FollowUpEmailAdvisor.ActionInput inp = new FollowUpEmailAdvisor.ActionInput();

        Test.startTest();
        List<FollowUpEmailAdvisor.ActionOutput> outs =
            FollowUpEmailAdvisor.getFollowUpTargets(
                new List<FollowUpEmailAdvisor.ActionInput>{ inp });
        Test.stopTest();

        System.assertEquals(0, outs[0].totalCount,
            '次回打ち合わせ設定済みの商談は対象外であるべき');
    }
}
