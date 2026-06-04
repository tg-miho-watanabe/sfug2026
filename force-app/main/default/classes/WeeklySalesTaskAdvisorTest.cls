@isTest
private class WeeklySalesTaskAdvisorTest {

    @TestSetup
    static void makeData() {
        Account acc = new Account(Name = 'テスト取引先');
        insert acc;

        Date today = Date.today();

        // 高額・今週Close・NextStep未入力の商談（高スコア想定）
        Opportunity oppHot = new Opportunity(
            Name      = 'ホット商談',
            StageName = 'Prospecting',
            CloseDate = today.addDays(2),
            Amount    = 2000000,
            AccountId = acc.Id
        );
        // 通常の商談
        Opportunity oppNormal = new Opportunity(
            Name      = '通常商談',
            StageName = 'Qualification',
            CloseDate = today.addDays(90),
            Amount    = 50000,
            NextStep  = '見積提出',
            AccountId = acc.Id
        );
        insert new List<Opportunity>{ oppHot, oppNormal };

        // 期限切れタスク（超優先）と期限なしタスク
        Task overdue = new Task(
            Subject      = '期限切れタスク',
            Status       = 'Not Started',
            Priority     = 'Normal',
            ActivityDate = today.addDays(-3),
            WhatId       = oppHot.Id,
            Description  = '至急対応'
        );
        Task noDue = new Task(
            Subject  = '期限なしタスク',
            Status   = 'Not Started',
            Priority = 'Normal'
        );
        insert new List<Task>{ overdue, noDue };

        // 今週のイベント
        DateTime startToday = DateTime.newInstance(today, Time.newInstance(10, 0, 0, 0));
        Event ev = new Event(
            Subject          = '今週の打ち合わせ',
            StartDateTime    = startToday,
            DurationInMinutes = 60,
            WhatId           = oppHot.Id
        );
        insert ev;

        // 商談に紐づく受信メール（直近）
        EmailMessage em = new EmailMessage(
            Subject     = '質問があります',
            FromName    = '取引先 担当',
            FromAddress = 'customer@example.com',
            Incoming    = true,
            Status      = '0',
            MessageDate = DateTime.now(),
            RelatedToId = oppHot.Id,
            TextBody    = 'お世話になっております。ご確認ください。'
        );
        insert em;
    }

    @isTest
    static void testGetPrioritizedTasks_default() {
        WeeklySalesTaskAdvisor.ActionInput inp = new WeeklySalesTaskAdvisor.ActionInput();
        // userId 省略 → ログインユーザー

        Test.startTest();
        List<WeeklySalesTaskAdvisor.ActionOutput> outs =
            WeeklySalesTaskAdvisor.getPrioritizedTasks(
                new List<WeeklySalesTaskAdvisor.ActionInput>{ inp });
        Test.stopTest();

        System.assertEquals(1, outs.size(), '出力は1件であるべき');
        WeeklySalesTaskAdvisor.ActionOutput out = outs[0];

        System.assert(out.totalCount > 0, '優先タスクが返却されるべき');
        System.assert(out.totalCount <= 10, '上位10件以内であるべき');
        System.assertNotEquals(null, out.prioritizedTasksJson, 'JSONが返却されるべき');

        // JSONをデシリアライズして内容を検証
        List<Object> items =
            (List<Object>) JSON.deserializeUntyped(out.prioritizedTasksJson);
        System.assertEquals(out.totalCount, items.size(),
            'totalCountとJSON件数が一致するべき');

        // スコア降順で並んでいることを確認
        Integer prevScore = null;
        Set<String> types = new Set<String>();
        for (Object o : items) {
            Map<String, Object> m = (Map<String, Object>) o;
            Integer score = (Integer) m.get('priorityScore');
            if (prevScore != null) {
                System.assert(score <= prevScore, 'スコアは降順であるべき');
            }
            prevScore = score;
            types.add((String) m.get('type'));
        }
        // 商談・タスク・イベント・メールのいずれも収集対象になっている
        System.assert(types.contains('Opportunity') || types.contains('Task')
            || types.contains('Event') || types.contains('Email'),
            '少なくとも1種類のレコードが含まれるべき');
    }

    @isTest
    static void testGetPrioritizedTasks_explicitUser() {
        WeeklySalesTaskAdvisor.ActionInput inp = new WeeklySalesTaskAdvisor.ActionInput();
        inp.userId = UserInfo.getUserId();

        Test.startTest();
        List<WeeklySalesTaskAdvisor.ActionOutput> outs =
            WeeklySalesTaskAdvisor.getPrioritizedTasks(
                new List<WeeklySalesTaskAdvisor.ActionInput>{ inp });
        Test.stopTest();

        System.assertEquals(1, outs.size(), '出力は1件であるべき');
        System.assert(outs[0].totalCount > 0, '明示ユーザー指定でも結果が返るべき');
    }

    @isTest
    static void testGetPrioritizedTasks_noData() {
        // データを所有しない別ユーザーで実行
        User otherUser = createMinimalUser();
        WeeklySalesTaskAdvisor.ActionInput inp = new WeeklySalesTaskAdvisor.ActionInput();
        inp.userId = otherUser.Id;

        Test.startTest();
        List<WeeklySalesTaskAdvisor.ActionOutput> outs =
            WeeklySalesTaskAdvisor.getPrioritizedTasks(
                new List<WeeklySalesTaskAdvisor.ActionInput>{ inp });
        Test.stopTest();

        System.assertEquals(0, outs[0].totalCount, 'データなしユーザーは0件であるべき');
    }

    static User createMinimalUser() {
        // 実行ユーザーと同じプロファイルを再利用（環境差異に依存しない）
        Id profileId = [
            SELECT ProfileId FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1
        ].ProfileId;
        String suffix = String.valueOf(DateTime.now().getTime());
        User u = new User(
            FirstName = 'No',
            LastName  = 'Data',
            Email     = 'nodata.user@example.com.invalid',
            Username  = 'nodata.user.' + suffix + '@example.com.invalid',
            Alias     = 'nodt',
            TimeZoneSidKey   = 'Asia/Tokyo',
            LocaleSidKey     = 'ja_JP',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'ja',
            ProfileId        = profileId
        );
        insert u;
        return u;
    }
}
