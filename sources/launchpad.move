module minter::launchpad {
    use std::error;
    use std::signer;
    use std::vector;
    use aptos_framework::coin;
    use std::option::{Self, Option};
    use aptos_std::smart_table::{Self, SmartTable};
    use aptos_framework::account::{Self, SignerCapability};
    use std::string::{Self, String};
    use aptos_framework::event;
    use aptos_framework::timestamp;
    use minter::utils;
    ///////////////////////  const  ///////////////////////
    const QUESTION_TYPE_SPECIFIED: u64 = 1;
    const QUESTION_TYPE_PUBLIC: u64 = 2;
    const CONFIG_SYMBOL: vector<u8> = b"HALO";
    ///////////////////////  error codes  ///////////////////////
    const EUNAUTHORIZED: u64 = 3;
    const EINVALID_ID: u64 = 4;
    const EINVALID_TYPE: u64 = 5;
    const EINVALID_PRICE: u64 = 6;
    const EINVALID_ANSWER: u64 = 7;
    const ECANNOT_SET: u64 = 8;
    const ECANNOT_CLOSE: u64 = 9;
    const ECANNOT_FOLLOW: u64 = 10;
    const ECANNOT_ONLOOK: u64 = 11;
    const ECANNOT_ANSWER: u64 = 12;
    const ECANNOT_VOTE: u64 = 13;
    const ECANNOT_CLAIM: u64 = 14;
    const ECANNOT_REPEAT_ONLOOK: u64 = 15;
    const EEXCESS_LIMIT: u64 = 16;
    const EINVALID_NUM: u64 = 19;
    const EINVALID_ARG: u64 = 20;
    const EINVALID_ANSWERER: u64 = 21;
    const ECANNOT_ADD_BONUS: u64 = 22;
    ///////////////////////  structs  ///////////////////////
    struct Management has key {
        owner: address,
        pending_owner: address,
        admin_signer: address, // provide signatures for users
        global_signer_cap: SignerCapability
    }

    struct FeeManagement has key {
        platform_fee_recipient: address
    }

    struct BasicConfig has key {
        questioner_num_ul: u64, // ul: upper_limit ll:lower_limit
        question_price_ll: u64, // the lowest price limit when create or follow a question
        onlook_price_permille_ll: u64, //%o e.g. 1-->0.001--> 0.1%
        onlook_price_permille_ul: u64,
        can_repeat_onlook: bool,
        // determine onlook duration
        onlook_single_extend_interval: u64,
        onlook_max_interval: u64,
        // determine how to allocate coins
        global_answer_allocate: AnswerPhaseAllocate,
        global_const_P: u64,
        global_onlook_allocate_belowP: OnlookPhaseAllocate,
        global_onlook_allocate_aboveP: OnlookPhaseAllocate
    }

    struct AnswerPhaseAllocate has store, copy {
        // the sum is 100
        to_answers_pct: u64, // pct-percentage e.g. 1-->0.01-->1%
        to_last_onlooker_pct: u64,
        to_platform_pct: u64
    }

    struct OnlookPhaseAllocate has store, copy {
        // the sum is 100
        to_questioners_pct: u64,
        to_answers_pct: u64,
        to_last_onlooker_pct: u64,
        to_platform_pct: u64
    }

    //////////////////////////////////////////////////////
    struct Question<phantom CoinType> has key {
        question_id: String,
        // onlook_price= total_question_price*onlook_price_permille/1000
        onlook_price_permille: u64, //%o
        type: u64, // specified or public
        specified_answerer: Option<address>,
        answer_end_at: u64,
        onlook_end_at: u64,
        is_closed: bool,
        const_P: u64,
        // questioner related
        questioners: vector<address>, // the first: creator; others: following questioners
        questioner_details: SmartTable<address, QuestionerDetail>,
        total_question_price: u64,
        // total_questioner_num=vector::length(&questioners);
        //
        // onlook related
        onlookers: SmartTable<address, OnlookerDetail>,
        total_onlook_num: u64,
        // total_onlook_price=onlook_price*total_onlook_num
        //
        // answer + vote related
        answer_vote_details: SmartTable<address, AnswerDetail>,
        total_answer_num: u64,
        total_voted_weight_on_answer_phase: u64,
        total_voted_weight_on_onlook_phase: u64,
        // total fund = total_question_price + total_onlook_price
        // 1. how to allocate total_question_price
        answer_allocate: AnswerPhaseAllocate,
        // 2. how to allocate total_onlook_price
        onlook_allocate_belowP: OnlookPhaseAllocate,
        onlook_allocate_aboveP: OnlookPhaseAllocate,
        onlook_allocate_detail: OnlookAllocateDetail,
        //
        last_onlooker_addr: address,
        has_claimed_last_onlooker_reward: bool,
        has_claimed_platform_fee: bool,
        //
        signer_cap: SignerCapability
    }

    struct OnlookAllocateDetail has store {
        variable_P: u64,
        // onlook phase, how the all onlook prices to allocate
        to_questioners_num: u64,
        to_answers_num: u64,
        to_last_onlooker_num: u64,
        to_platform_num: u64
    }

    struct QuestionerDetail has store {
        quest_or_follow_price: u64,
        voted_to: address, // an answerer's address; vote weight= quest_or_follow_price
        has_claimed_onlook_phase_reward: bool
    }

    struct OnlookerDetail has store, drop {
        onlook_num: u64,
        voted_to: address //voted to which answerer --> onlook vote weight= onlook_num *onlook_price
    }

    struct AnswerDetail has store {
        answer_id: String,
        voted_weight_on_answer_phase: u64,
        voted_weight_on_onlook_phase: u64,
        has_claimd_answer_phase_reward: bool,
        has_claimd_onlook_phase_reward: bool
    }

    ///////////////////////  events   ///////////////////////
    #[event]
    struct CreateQuestionEvent has drop, store {
        creator: address,
        question_id: String,
        question_account_addr: address,
        price: u64
    }

    #[event]
    struct CloseQuestionEvent has drop, store {
        question_id: String,
        closer: address
    }

    #[event]
    struct FollowQuestionEvent has drop, store {
        question_id: String,
        follower: address,
        price: u64
    }

    #[event]
    struct OnlookQuestionEvent has drop, store {
        question_id: String,
        onlooker: address,
        onlook_num: u64,
        new_onlook_end_at: u64,
        price: u64
    }

    #[event]
    struct AnswerQuestionEvent has drop, store {
        question_id: String,
        answerer: address,
        answer_id: String
    }

    #[event]
    struct UserUpdateVoteEvent has drop, store {
        voter: address,
        question_id: String,
        answerer: address,
        answer_id: String,
        vote_weight: u64,
        phase: String //"answer" or "onlook"
    }

    #[event]
    struct AnswerVotedWeightUpdatedEvent has drop, store {
        answerer: address,
        answer_id: String,
        new_voted_weight_on_answer_phase: u64,
        new_voted_weight_on_onlook_phase: u64
    }

    #[event]
    struct RewardClaimedEvent has drop, store {
        claimer: address,
        question_id: String,
        amount: u64
    }

    #[event]
    struct OwnershipTransferredEvent has drop, store {
        new_owner: address
    }

    /// Called as part of deployment to initialize the module.
    fun init_module(self_signer: &signer) {
        let (resource_account, signer_cap): (signer, SignerCapability) =
            account::create_resource_account(self_signer, CONFIG_SYMBOL);
        move_to(
            &resource_account,
            Management {
                owner: @owner,
                pending_owner: @0x0,
                admin_signer: @admin_signer,
                global_signer_cap: signer_cap
            }
        );
        move_to(
            &resource_account,
            FeeManagement { platform_fee_recipient: @fee_recipient }
        );
        move_to(
            &resource_account,
            BasicConfig {
                questioner_num_ul: 100,
                question_price_ll: 5000000, // create or follow a question( assume decimals=6)
                onlook_price_permille_ll: 5, //%o
                onlook_price_permille_ul: 15, //%o
                can_repeat_onlook: false,
                onlook_single_extend_interval: 30 * 60, // 30min
                onlook_max_interval: 72 * 60 * 60, // 72hour
                global_answer_allocate: AnswerPhaseAllocate {
                    to_answers_pct: 65, //% e.g. 65-->65%
                    to_last_onlooker_pct: 30,
                    to_platform_pct: 5
                },
                global_const_P: 100,
                global_onlook_allocate_belowP: OnlookPhaseAllocate {
                    to_questioners_pct: 30,
                    to_answers_pct: 30,
                    to_last_onlooker_pct: 35,
                    to_platform_pct: 5
                },
                global_onlook_allocate_aboveP: OnlookPhaseAllocate {
                    to_questioners_pct: 45,
                    to_answers_pct: 35,
                    to_last_onlooker_pct: 15,
                    to_platform_pct: 5
                }
            }
        );

    }

    public entry fun create_question<CoinType>(
        creator: &signer,
        admin_signer: &signer,
        question_id: String,
        question_price: u64,
        onlook_price_permille: u64,
        type: u64,
        specified_answerer: Option<address>,
        answer_end_at: u64,
        initial_onlook_end_at: u64
    ) acquires Management, BasicConfig {
        // 1. verify admin_signer
        check_is_admin_signer(admin_signer);
        let managment: &Management = borrow_global<Management>(config_resource_address());
        let configs: &BasicConfig = borrow_global<BasicConfig>(config_resource_address());

        let creator_addr: address = signer::address_of(creator);
        // 2. verify question id
        let question_addr: address = question_resource_address(question_id);
        assert!(
            !exists<Question<CoinType>>(question_addr),
            error::already_exists(EINVALID_ID)
        );
        // 3. verify type and price
        assert!(
            type == QUESTION_TYPE_SPECIFIED || type == QUESTION_TYPE_PUBLIC,
            error::invalid_state(EINVALID_TYPE)
        );
        // public type can't specify answerer
        if (type == QUESTION_TYPE_PUBLIC)
            assert!(
                option::is_none(&specified_answerer),
                error::invalid_argument(EINVALID_ARG)
            );
        assert!(
            question_price >= configs.question_price_ll,
            error::out_of_range(EINVALID_PRICE)
        );
        assert!(
            onlook_price_permille >= configs.onlook_price_permille_ll
                && onlook_price_permille <= configs.onlook_price_permille_ul
                && initial_onlook_end_at > answer_end_at,
            error::out_of_range(EINVALID_ARG)
        );

        // 4. create question's resource account
        let config_signer: signer =
            account::create_signer_with_capability(&managment.global_signer_cap);

        let question_id_vector: vector<u8> = *string::bytes(&question_id);
        let (question_signer, signer_cap): (signer, SignerCapability) =
            account::create_resource_account(&config_signer, question_id_vector);

        coin::register<CoinType>(&question_signer);
        // 5. pay coins: questioner--> question's resource account
        utils::pay_to<CoinType>(
            creator,
            question_addr,
            question_price,
            string::utf8(b"create_question")
        );

        // 6. store question infos
        let questioners = vector::empty<address>();
        vector::push_back(&mut questioners, creator_addr);

        let questioner_details = smart_table::new<address, QuestionerDetail>();
        smart_table::add(
            &mut questioner_details,
            creator_addr,
            QuestionerDetail {
                quest_or_follow_price: question_price,
                voted_to: @0x0,
                has_claimed_onlook_phase_reward: false
            }
        );
        // calculate initial variable_P = phase1_to_last_onlooker/ onlook_price
        // phase1_to_last_onlooker= question.total_question_price* answer_phase_allocate.to_last_onlooker_pct / 100
        // onlook_price=question.total_question_price * question.onlook_price_permille / 1000;
        let initial_var_P: u64 =
            configs.global_answer_allocate.to_last_onlooker_pct * 10
                / onlook_price_permille;

        move_to(
            &question_signer,
            Question<CoinType> {
                question_id,
                onlook_price_permille,
                type,
                specified_answerer,
                answer_end_at,
                onlook_end_at: initial_onlook_end_at,
                is_closed: false,
                const_P: configs.global_const_P,
                questioners,
                questioner_details,
                total_question_price: question_price,
                onlookers: smart_table::new<address, OnlookerDetail>(),
                total_onlook_num: 0,
                answer_vote_details: smart_table::new<address, AnswerDetail>(),
                total_answer_num: 0,
                total_voted_weight_on_answer_phase: 0,
                total_voted_weight_on_onlook_phase: 0,
                answer_allocate: *&configs.global_answer_allocate,
                onlook_allocate_belowP: *&configs.global_onlook_allocate_belowP,
                onlook_allocate_aboveP: *&configs.global_onlook_allocate_aboveP,
                onlook_allocate_detail: OnlookAllocateDetail {
                    variable_P: initial_var_P,
                    to_questioners_num: 0,
                    to_answers_num: 0,
                    to_last_onlooker_num: 0,
                    to_platform_num: 0
                },
                last_onlooker_addr: @0x0,
                has_claimed_last_onlooker_reward: false,
                has_claimed_platform_fee: false,
                signer_cap
            }
        );

        event::emit(
            CreateQuestionEvent {
                creator: creator_addr,
                question_id: question_id,
                question_account_addr: question_addr,
                price: question_price
            }
        );
    }

    /// only admin or question_creator can close a question
    public entry fun close_question<CoinType>(
        closer: &signer, question_id: String
    ) acquires Management, Question {
        let management: &Management =
            borrow_global<Management>(config_resource_address());
        // get question info
        let question_addr: address = question_resource_address(question_id);
        assert!(
            exists<Question<CoinType>>(question_addr),
            error::not_found(EINVALID_ID)
        );
        let question = borrow_global_mut<Question<CoinType>>(question_addr);
        let closer_addr: address = signer::address_of(closer);
        // check: not closed + no answers
        assert!(
            !question.is_closed && question.total_answer_num == 0,
            error::invalid_state(ECANNOT_CLOSE)
        );
        // question creator or admin?
        let question_creator: address = *vector::borrow(&question.questioners, 0);
        assert!(
            closer_addr == question_creator || closer_addr == management.admin_signer,
            error::unauthenticated(EUNAUTHORIZED)
        );
        // close
        question.is_closed = true;
        // refund coins: question object -> each questioner
        let question_signer: signer =
            account::create_signer_with_capability(&question.signer_cap);
        vector::for_each_ref(
            &question.questioners,
            |user| {
                let refund_detail: &QuestionerDetail =
                    smart_table::borrow(&question.questioner_details, *user);
                // pay coins: question--> user
                utils::pay_to<CoinType>(
                    &question_signer,
                    *user,
                    refund_detail.quest_or_follow_price,
                    string::utf8(b"close_question")
                );
            }
        );
        event::emit(CloseQuestionEvent { question_id, closer: closer_addr });
    }

    public entry fun follow_question<CoinType>(
        follower: &signer,
        admin_signer: &signer,
        question_id: String,
        follow_question_price: u64
    ) acquires Management, BasicConfig, Question {
        // check admin_signer
        check_is_admin_signer(admin_signer);
        let configs: &BasicConfig = borrow_global<BasicConfig>(config_resource_address());

        let follower_addr: address = signer::address_of(follower);
        // get question info
        let question_addr: address = question_resource_address(question_id);
        assert!(
            exists<Question<CoinType>>(question_addr),
            error::not_found(EINVALID_ID)
        );
        let question = borrow_global_mut<Question<CoinType>>(question_addr);
        // check: not closed + in answer phase + has't followed before + not answerer
        let now_time: u64 = timestamp::now_seconds();
        assert!(
            !question.is_closed
                && now_time < question.answer_end_at
                && !vector::contains(&question.questioners, &follower_addr)
                && !smart_table::contains(&question.answer_vote_details, follower_addr),
            error::invalid_state(ECANNOT_FOLLOW)
        );

        // check price
        assert!(
            follow_question_price >= configs.question_price_ll,
            error::out_of_range(EINVALID_PRICE)
        );
        // check follow upper limit
        assert!(
            vector::length(&question.questioners) < configs.questioner_num_ul,
            error::out_of_range(EEXCESS_LIMIT)
        );
        // pay coins: user--> question's resource account
        utils::pay_to<CoinType>(
            follower,
            question_addr,
            follow_question_price,
            string::utf8(b"follow_question")
        );
        // update question detail
        vector::push_back(&mut question.questioners, follower_addr);
        smart_table::add(
            &mut question.questioner_details,
            follower_addr,
            QuestionerDetail {
                quest_or_follow_price: follow_question_price,
                voted_to: @0x0,
                has_claimed_onlook_phase_reward: false
            }
        );
        question.total_question_price = question.total_question_price
            + follow_question_price;
        // event
        event::emit(
            FollowQuestionEvent {
                question_id,
                follower: follower_addr,
                price: follow_question_price
            }
        );
    }

    public entry fun answer_question<CoinType>(
        answerer: &signer,
        admin_signer: &signer,
        question_id: String,
        answer_id: String
    ) acquires Management, Question {
        check_is_admin_signer(admin_signer);
        let answerer_addr: address = signer::address_of(answerer);
        // get question
        let question_addr: address = question_resource_address(question_id);
        assert!(
            exists<Question<CoinType>>(question_addr),
            error::not_found(EINVALID_ID)
        );
        let question = borrow_global_mut<Question<CoinType>>(question_addr);
        // check: not closed + not questioner + has't answered
        assert!(
            !question.is_closed
                && !vector::contains(&question.questioners, &answerer_addr)
                && !smart_table::contains(&question.answer_vote_details, answerer_addr),
            error::invalid_state(ECANNOT_ANSWER)
        );
        let now_time: u64 = timestamp::now_seconds();
        // in answer period or
        // in onlook period and has voted in answer period(so that, this answer will not influence the allocate of answer period's coins)
        assert!(
            now_time < question.answer_end_at
                || (
                    now_time < question.onlook_end_at
                        && question.total_voted_weight_on_answer_phase > 0
                ),
            error::invalid_state(ECANNOT_ANSWER)
        );
        // specified question
        if (question.type == QUESTION_TYPE_SPECIFIED) {
            // for specified question, check: not expired + specified answerer
            assert!(
                now_time < question.answer_end_at
                    && option::contains(&question.specified_answerer, &answerer_addr),
                error::invalid_state(EINVALID_ANSWERER)
            );
            // enter the onlook phase immediately: update answer_end_at and onlook_end_at
            let time_diff: u64 = question.answer_end_at - now_time;
            question.answer_end_at = now_time;
            question.onlook_end_at = question.onlook_end_at - time_diff;
        };
        // update question: answer_vote_details and total_answer_num
        smart_table::add(
            &mut question.answer_vote_details,
            answerer_addr,
            AnswerDetail {
                answer_id,
                voted_weight_on_answer_phase: 0,
                voted_weight_on_onlook_phase: 0,
                has_claimd_answer_phase_reward: false,
                has_claimd_onlook_phase_reward: false
            }
        );
        question.total_answer_num = question.total_answer_num + 1;
        // event
        event::emit(
            AnswerQuestionEvent { question_id, answerer: answerer_addr, answer_id }
        )
    }

    public entry fun onlook_question<CoinType>(
        onlooker: &signer, question_id: String
    ) acquires BasicConfig, Question {
        let configs: &BasicConfig = borrow_global<BasicConfig>(config_resource_address());
        // don't need admin check
        let onlooker_addr: address = signer::address_of(onlooker);
        // get question
        let question_addr: address = question_resource_address(question_id);
        assert!(
            exists<Question<CoinType>>(question_addr),
            error::not_found(EINVALID_ID)
        );
        let question: &mut Question<CoinType> =
            borrow_global_mut<Question<CoinType>>(question_addr);
        let now_time: u64 = timestamp::now_seconds();
        // check: not closed + in onlook period + questioner can't onlook + at least contain one answer
        assert!(
            !question.is_closed
                && now_time > question.answer_end_at
                && now_time < question.onlook_end_at
                && !vector::contains(&question.questioners, &onlooker_addr)
                && question.total_answer_num > 0,
            error::invalid_state(ECANNOT_ONLOOK)
        );

        // can repeat onlook?
        if (!configs.can_repeat_onlook)
            assert!(
                !smart_table::contains(&question.onlookers, onlooker_addr),
                error::invalid_state(ECANNOT_REPEAT_ONLOOK)
            );

        // pay coins: user--> question object
        // u64 is enough, will not overflow
        let onlook_price: u64 =
            question.total_question_price * question.onlook_price_permille / 1000;
        utils::pay_to<CoinType>(
            onlooker,
            question_addr,
            onlook_price,
            string::utf8(b"onlook_question")
        );
        // extend question's onlook_end_at
        question.onlook_end_at = utils::update_end_time(
            question.onlook_end_at,
            configs.onlook_single_extend_interval,
            configs.onlook_max_interval
        );
        // update question's onlook infos
        // -- onlookers: Table<address, OnlookerDetail>,
        // -- total_onlook_num: u64,
        // -- last_onlooker_addr
        question.last_onlooker_addr = onlooker_addr;
        question.total_onlook_num = question.total_onlook_num + 1;
        let onlooker_detail: &mut OnlookerDetail =
            smart_table::borrow_mut_with_default(
                &mut question.onlookers,
                onlooker_addr,
                OnlookerDetail { onlook_num: 0, voted_to: @0x0 }
            );
        onlooker_detail.onlook_num = onlooker_detail.onlook_num + 1;

        if (onlooker_detail.voted_to != @0x0) {
            // has voted and this's repeat onlook: append vote info automatically
            let voted_answer: &mut AnswerDetail =
                smart_table::borrow_mut(
                    &mut question.answer_vote_details, onlooker_detail.voted_to
                );
            let added_voted_weight: u64 = onlook_price;
            voted_answer.voted_weight_on_onlook_phase = voted_answer.voted_weight_on_onlook_phase
                + added_voted_weight;
            question.total_voted_weight_on_onlook_phase = question.total_voted_weight_on_onlook_phase
                + added_voted_weight;

            let onlooker_total_vote_weight: u64 = onlooker_detail.onlook_num
                * onlook_price;
            // events
            event::emit(
                UserUpdateVoteEvent {
                    voter: onlooker_addr,
                    question_id,
                    answerer: onlooker_detail.voted_to,
                    answer_id: voted_answer.answer_id,
                    vote_weight: onlooker_total_vote_weight,
                    phase: string::utf8(b"onlook")
                }
            );
            event::emit(
                AnswerVotedWeightUpdatedEvent {
                    answerer: onlooker_detail.voted_to,
                    answer_id: voted_answer.answer_id,
                    new_voted_weight_on_answer_phase: voted_answer.voted_weight_on_answer_phase,
                    new_voted_weight_on_onlook_phase: voted_answer.voted_weight_on_onlook_phase
                }
            );

        };

        // update question's onlook_allocate_detail
        let answer_phase_to_last_onlooker: u64 =
            question.total_question_price
                * question.answer_allocate.to_last_onlooker_pct / 100;
        let temp: &mut OnlookAllocateDetail = &mut question.onlook_allocate_detail;
        // according 'onlook_allocate_belowP' or 'onlook_allocate_aboveP' to allocate coins
        let allocate: &OnlookPhaseAllocate =
            if (temp.variable_P < question.const_P) {
                &question.onlook_allocate_belowP
            } else {
                &question.onlook_allocate_aboveP
            };

        temp.to_questioners_num = temp.to_questioners_num
            + onlook_price * allocate.to_questioners_pct / 100;
        temp.to_answers_num = temp.to_answers_num
            + onlook_price * allocate.to_answers_pct / 100;
        temp.to_last_onlooker_num = temp.to_last_onlooker_num
            + onlook_price * allocate.to_last_onlooker_pct / 100;
        temp.to_platform_num = temp.to_platform_num
            + onlook_price * allocate.to_platform_pct / 100;
        temp.variable_P = (answer_phase_to_last_onlooker + temp.to_last_onlooker_num)
            / onlook_price;

        // event
        event::emit(
            OnlookQuestionEvent {
                question_id,
                onlooker: onlooker_addr,
                onlook_num: onlooker_detail.onlook_num,
                new_onlook_end_at: question.onlook_end_at,
                price: onlook_price
            }
        );
    }

    // in this phase, only questioners can vote or modify their vote
    // only public question can be voted, specified question don't need vote
    public entry fun answer_phase_vote<CoinType>(
        voter: &signer, question_id: String, answerer_addr: address
    ) acquires Question {
        // get question
        let question_addr: address = question_resource_address(question_id);
        assert!(
            exists<Question<CoinType>>(question_addr),
            error::not_found(EINVALID_ID)
        );
        let question: &mut Question<CoinType> =
            borrow_global_mut<Question<CoinType>>(question_addr);
        let now_time: u64 = timestamp::now_seconds();
        let voter_addr: address = signer::address_of(voter);
        // check: not close + type=public + only in answer period can vote +only questioner can vote
        assert!(
            !question.is_closed
                && question.type == QUESTION_TYPE_PUBLIC
                && now_time < question.answer_end_at
                && vector::contains(&question.questioners, &voter_addr),
            error::invalid_state(ECANNOT_VOTE)
        );
        // check answer exist
        assert!(
            smart_table::contains(&question.answer_vote_details, answerer_addr),
            error::not_found(EINVALID_ANSWER)
        );

        let questioner_detail: &mut QuestionerDetail =
            smart_table::borrow_mut(&mut question.questioner_details, voter_addr);
        let vote_weight: u64 = questioner_detail.quest_or_follow_price;
        // first vote or modify vote
        if (questioner_detail.voted_to != @0x0) {
            // modify vote: delete old vote info, then add new vote info
            let old_voted_answer: &mut AnswerDetail =
                smart_table::borrow_mut(
                    &mut question.answer_vote_details, questioner_detail.voted_to
                );
            old_voted_answer.voted_weight_on_answer_phase = old_voted_answer.voted_weight_on_answer_phase
                - vote_weight;

            // question.total_voted_weight_on_answer_phase: don't change
            event::emit(
                AnswerVotedWeightUpdatedEvent {
                    answerer: questioner_detail.voted_to,
                    answer_id: old_voted_answer.answer_id,
                    new_voted_weight_on_answer_phase: old_voted_answer.voted_weight_on_answer_phase,
                    new_voted_weight_on_onlook_phase: old_voted_answer.voted_weight_on_onlook_phase
                }
            );

        } else { // first vote: just add new vote info
            question.total_voted_weight_on_answer_phase = question.total_voted_weight_on_answer_phase
                + vote_weight;
        };
        let new_voted_answer: &mut AnswerDetail =
            smart_table::borrow_mut(&mut question.answer_vote_details, answerer_addr);
        new_voted_answer.voted_weight_on_answer_phase = new_voted_answer.voted_weight_on_answer_phase
            + vote_weight;
        questioner_detail.voted_to = answerer_addr;
        // events
        event::emit(
            UserUpdateVoteEvent {
                voter: voter_addr,
                question_id,
                answerer: answerer_addr,
                answer_id: new_voted_answer.answer_id,
                vote_weight,
                phase: string::utf8(b"answer")
            }
        );
        event::emit(
            AnswerVotedWeightUpdatedEvent {
                answerer: answerer_addr,
                answer_id: new_voted_answer.answer_id,
                new_voted_weight_on_answer_phase: new_voted_answer.voted_weight_on_answer_phase,
                new_voted_weight_on_onlook_phase: new_voted_answer.voted_weight_on_onlook_phase
            }
        );
    }

    // in this phase, only onlookers can vote or modify their vote
    // only public question can be voted, specified question don't need vote
    public entry fun onlook_phase_vote<CoinType>(
        voter: &signer, question_id: String, answerer_addr: address
    ) acquires Question {
        // get question
        let question_addr: address = question_resource_address(question_id);
        assert!(
            exists<Question<CoinType>>(question_addr),
            error::not_found(EINVALID_ID)
        );
        let question = borrow_global_mut<Question<CoinType>>(question_addr);
        let now_time: u64 = timestamp::now_seconds();
        let voter_addr: address = signer::address_of(voter);

        // check: not close + type=public + in onlook period + only onlooker can vote
        assert!(
            !question.is_closed
                && question.type == QUESTION_TYPE_PUBLIC
                && now_time > question.answer_end_at
                && now_time < question.onlook_end_at
                && smart_table::contains(&question.onlookers, voter_addr),
            error::invalid_state(ECANNOT_VOTE)
        );

        // check answer exist
        assert!(
            smart_table::contains(&question.answer_vote_details, answerer_addr),
            error::not_found(EINVALID_ANSWER)
        );

        // first vote or modify vote
        let onlooker_detail: &mut OnlookerDetail =
            smart_table::borrow_mut(&mut question.onlookers, voter_addr);
        let onlook_price: u64 =
            question.total_question_price * question.onlook_price_permille / 1000;

        let vote_weight: u64 = onlooker_detail.onlook_num * onlook_price;

        if (onlooker_detail.voted_to != @0x0) {
            // delete old vote info, then add new vote info
            let old_voted_answer: &mut AnswerDetail =
                smart_table::borrow_mut(
                    &mut question.answer_vote_details, onlooker_detail.voted_to
                );
            old_voted_answer.voted_weight_on_onlook_phase = old_voted_answer.voted_weight_on_onlook_phase
                - vote_weight;

            // question.total_voted_weight_on_onlook_phase: don't change
            event::emit(
                AnswerVotedWeightUpdatedEvent {
                    answerer: onlooker_detail.voted_to,
                    answer_id: old_voted_answer.answer_id,
                    new_voted_weight_on_answer_phase: old_voted_answer.voted_weight_on_answer_phase,
                    new_voted_weight_on_onlook_phase: old_voted_answer.voted_weight_on_onlook_phase
                }
            );

        } else { // just add new vote info
            question.total_voted_weight_on_onlook_phase = question.total_voted_weight_on_onlook_phase
                + vote_weight;
        };
        let new_voted_answer: &mut AnswerDetail =
            smart_table::borrow_mut(&mut question.answer_vote_details, answerer_addr);
        new_voted_answer.voted_weight_on_onlook_phase = new_voted_answer.voted_weight_on_onlook_phase
            + vote_weight;
        onlooker_detail.voted_to = answerer_addr;

        event::emit(
            UserUpdateVoteEvent {
                voter: voter_addr,
                question_id,
                answerer: answerer_addr,
                answer_id: new_voted_answer.answer_id,
                vote_weight,
                phase: string::utf8(b"onlook")
            }
        );
        event::emit(
            AnswerVotedWeightUpdatedEvent {
                answerer: answerer_addr,
                answer_id: new_voted_answer.answer_id,
                new_voted_weight_on_answer_phase: new_voted_answer.voted_weight_on_answer_phase,
                new_voted_weight_on_onlook_phase: new_voted_answer.voted_weight_on_onlook_phase
            }
        );

    }

    public entry fun claim_question_rewards<CoinType>(
        claimer: &signer, question_id: String
    ) acquires Question, FeeManagement {
        // get question
        let question_addr: address = question_resource_address(question_id);
        assert!(
            exists<Question<CoinType>>(question_addr),
            error::not_found(EINVALID_ID)
        );
        let question = borrow_global_mut<Question<CoinType>>(question_addr);
        // check: not close + not in answer phase(answer phase can't start claiming) + has answered
        let now_time: u64 = timestamp::now_seconds();
        assert!(
            !question.is_closed
                && now_time > question.answer_end_at
                && question.total_answer_num > 0,
            error::invalid_state(ECANNOT_CLAIM)
        );

        let claimer_addr: address = signer::address_of(claimer);
        let is_questioner: bool = vector::contains(&question.questioners, &claimer_addr);
        let is_answerer: bool =
            smart_table::contains(&question.answer_vote_details, claimer_addr);
        let question_signer: signer =
            account::create_signer_with_capability(&question.signer_cap);
        let can_claim_num: u64 = 0;
        // 1. currently in which settle phase
        //      1. answer_end_at ~ onlook_end_at: the first settlement, answerers + platform can claim
        //      2. onlook_end_at ~ : the second settlement, answerer + questioners + last onlooker + platform can claim
        // 2. claimer's role:
        //      1. just questioner
        //      2. just answerer
        //      3. just the last onlooker
        //      4. answerer + the last onlooker
        if (is_answerer) {
            let answer_detail: &mut AnswerDetail =
                smart_table::borrow_mut(&mut question.answer_vote_details, claimer_addr);
            if (!answer_detail.has_claimd_answer_phase_reward) {
                let all_coins: u64 =
                    question.total_question_price
                        * question.answer_allocate.to_answers_pct / 100;

                if (question.total_voted_weight_on_answer_phase == 0) {
                    // distribute equally
                    can_claim_num = can_claim_num
                        + all_coins / question.total_answer_num;
                } else {
                    // distribute according to voted weight
                    can_claim_num = can_claim_num
                        + ((all_coins as u128)
                            * (answer_detail.voted_weight_on_answer_phase as u128)
                            / (question.total_voted_weight_on_answer_phase as u128) as u64);

                };
                answer_detail.has_claimd_answer_phase_reward = true;
            };

            if (now_time > question.onlook_end_at
                && !answer_detail.has_claimd_onlook_phase_reward) {
                let total_voted_weight: u64 =
                    question.total_voted_weight_on_answer_phase
                        + question.total_voted_weight_on_onlook_phase;
                if (total_voted_weight == 0) {
                    // distribute equally
                    can_claim_num = can_claim_num
                        + question.onlook_allocate_detail.to_answers_num
                            / question.total_answer_num;

                } else {
                    // distribute according to voted weight
                    let answer_total_voted_weight: u64 =
                        answer_detail.voted_weight_on_answer_phase
                            + answer_detail.voted_weight_on_onlook_phase;
                    can_claim_num = can_claim_num
                        + ((question.onlook_allocate_detail.to_answers_num as u128)
                            * (answer_total_voted_weight as u128)
                            / (total_voted_weight as u128) as u64);
                };
                answer_detail.has_claimd_onlook_phase_reward = true;
            }
        };

        // the second settlement -- answerer+ questioners + last onlooker + platform can claim
        if (now_time > question.onlook_end_at) {
            // [0] settle platform fee
            if (!question.has_claimed_platform_fee) {
                let feeManage: &FeeManagement =
                    borrow_global<FeeManagement>(config_resource_address());
                let platform_fee: u64 =
                    question.total_question_price
                        * question.answer_allocate.to_platform_pct / 100
                        + question.onlook_allocate_detail.to_platform_num;
                // pay coins: question--> platform
                utils::pay_to<CoinType>(
                    &question_signer,
                    feeManage.platform_fee_recipient,
                    platform_fee,
                    string::utf8(b"claim_reward")
                );
                event::emit(
                    RewardClaimedEvent {
                        claimer: feeManage.platform_fee_recipient,
                        question_id,
                        amount: platform_fee
                    }
                );
                question.has_claimed_platform_fee = true;
            };
            // 1.claimer is answerer-- settled above
            // 2.claimer is questioner
            if (is_questioner) {
                let questioner_detail: &mut QuestionerDetail =
                    smart_table::borrow_mut(
                        &mut question.questioner_details, claimer_addr
                    );

                if (!questioner_detail.has_claimed_onlook_phase_reward) {
                    can_claim_num = can_claim_num
                        + ((question.onlook_allocate_detail.to_questioners_num as u128)
                            * (questioner_detail.quest_or_follow_price as u128)
                            / (question.total_question_price as u128) as u64);

                    questioner_detail.has_claimed_onlook_phase_reward = true;
                }
            };

            // 3.claimer is the last onlooker
            if (question.last_onlooker_addr == claimer_addr
                && !question.has_claimed_last_onlooker_reward) {
                let answer_phase_to_last_onlooker: u64 =
                    question.total_question_price
                        * question.answer_allocate.to_last_onlooker_pct / 100;
                can_claim_num = can_claim_num + answer_phase_to_last_onlooker
                    + question.onlook_allocate_detail.to_last_onlooker_num;

                question.has_claimed_last_onlooker_reward = true;
            };
        };
        // pay coins: question--> claimer
        if (can_claim_num > 0)
            utils::pay_to<CoinType>(
                &question_signer,
                claimer_addr,
                can_claim_num,
                string::utf8(b"claim_reward")
            );
        // event
        event::emit(
            RewardClaimedEvent { claimer: claimer_addr, question_id, amount: can_claim_num }
        );
    }

    // ======================================== admin_signer functions ==================================
    // close_question: see above
    public entry fun set_specified_answerer<CoinType>(
        admin_signer: &signer, question_id: String, specified_answerer: address
    ) acquires Management, Question {
        // check authority
        check_is_admin_signer(admin_signer);
        // question related verify
        let question_addr: address = question_resource_address(question_id);
        assert!(
            exists<Question<CoinType>>(question_addr),
            error::not_found(EINVALID_ID)
        );
        let question: &mut Question<CoinType> =
            borrow_global_mut<Question<CoinType>>(question_addr);
        // // not previously specified-- wether to restrict
        // assert!(
        //     option::is_none(&question.specified_answerer),
        //     error::invalid_state(ECANNOT_SET)
        // );
        // not answered yet
        assert!(
            question.type == QUESTION_TYPE_SPECIFIED && question.total_answer_num == 0,
            error::invalid_state(ECANNOT_SET)
        );
        // update
        question.specified_answerer = option::some(specified_answerer);
    }

    // public entry fun set_question_end_time<CoinType>(
    //     admin_signer: &signer,
    //     question_id: String,
    //     new_answer_end_time: u64,
    //     new_onlook_end_time: u64
    // ) acquires Management, Question {
    //     // check authority
    //     check_is_admin_signer(admin_signer);
    //     // question related verify
    //     let question_addr: address = question_resource_address(question_id);
    //     assert!(
    //         exists<Question<CoinType>>(question_addr),
    //         error::not_found(EINVALID_ID)
    //     );
    //     let question: &mut Question<CoinType> =
    //         borrow_global_mut<Question<CoinType>>(question_addr);

    //     // update
    //     question.answer_end_at = new_answer_end_time;
    //     question.onlook_end_at = new_onlook_end_time;
    // }

    public entry fun batch_add_bonus_to_last_onlooker<CoinType>(
        admin_signer: &signer, question_ids: vector<String>, amounts: vector<u64>
    ) acquires Management, Question {
        // check authority
        check_is_admin_signer(admin_signer);
        assert!(
            vector::length(&question_ids) == vector::length(&amounts),
            error::invalid_argument(EINVALID_ARG)
        );
        let now_time: u64 = timestamp::now_seconds();
        vector::enumerate_ref(
            &question_ids,
            |i, question_id| {
                let question_addr: address = question_resource_address(*question_id);
                let question: &mut Question<CoinType> =
                    borrow_global_mut<Question<CoinType>>(question_addr);
                let amount: u64 = *vector::borrow(&amounts, i);
                assert!(
                    now_time < question.onlook_end_at,
                    error::invalid_state(ECANNOT_ADD_BONUS)
                );
                // pay coins: admin --> question's resource account
                utils::pay_to<CoinType>(
                    admin_signer,
                    question_addr,
                    amount,
                    string::utf8(b"add_bonus")
                );
                // update
                let temp: &mut OnlookAllocateDetail = &mut question.onlook_allocate_detail;
                temp.to_last_onlooker_num = temp.to_last_onlooker_num + amount;
            }
        );
    }

    // ======================================== owner functions ==================================

    public entry fun update_fee_recipient_by_owner(
        owner: &signer, new_recipient: address
    ) acquires Management, FeeManagement {
        check_is_owner(owner);
        let fee_management: &mut FeeManagement =
            borrow_global_mut<FeeManagement>(config_resource_address());
        //update
        fee_management.platform_fee_recipient = new_recipient;
    }

    public entry fun update_admin_signer_by_owner(
        owner: &signer, new_admin_signer: address
    ) acquires Management {
        // verify owner
        let management: &mut Management =
            borrow_global_mut<Management>(config_resource_address());
        assert!(
            signer::address_of(owner) == management.owner,
            error::unauthenticated(EUNAUTHORIZED)
        );
        // update
        management.admin_signer = new_admin_signer;
    }

    public entry fun transfer_ownership(owner: &signer, new_owner: address) acquires Management {
        // verify owner
        let management: &mut Management =
            borrow_global_mut<Management>(config_resource_address());
        assert!(
            signer::address_of(owner) == management.owner,
            error::unauthenticated(EUNAUTHORIZED)
        );
        // update
        management.pending_owner = new_owner;
        // event
    }

    public entry fun accept_ownership(new_owner: &signer) acquires Management {
        // verify pending owner
        let management: &mut Management =
            borrow_global_mut<Management>(config_resource_address());
        assert!(
            signer::address_of(new_owner) == management.pending_owner,
            error::unauthenticated(EUNAUTHORIZED)
        );
        // update
        management.owner = signer::address_of(new_owner);
        management.pending_owner = @0x0;
        // event
        event::emit(OwnershipTransferredEvent { new_owner: management.owner });
    }

    public entry fun update_basic_configs_by_owner(
        owner: &signer,
        new_questioner_num_ul: u64,
        new_question_price_ll: u64,
        new_onlook_price_permille_ll: u64,
        new_onlook_price_permille_ul: u64,
        new_const_P: u64,
        new_can_repeat: bool,
        new_single_extend_interval: u64,
        new_onlook_max_interval: u64
    ) acquires BasicConfig, Management {
        // verify owner
        check_is_owner(owner);
        let configs: &mut BasicConfig =
            borrow_global_mut<BasicConfig>(config_resource_address());
        // update
        configs.questioner_num_ul = new_questioner_num_ul;
        configs.question_price_ll = new_question_price_ll;
        configs.onlook_price_permille_ll = new_onlook_price_permille_ll;
        configs.onlook_price_permille_ul = new_onlook_price_permille_ul;
        configs.can_repeat_onlook = new_can_repeat;
        configs.onlook_single_extend_interval = new_single_extend_interval;
        configs.onlook_max_interval = new_onlook_max_interval;
        configs.global_const_P = new_const_P;
    }

    public entry fun update_global_answer_allocate_by_owner(
        owner: &signer, new_to_answers_pct: u64, new_to_last_onlooker_pct: u64
    ) acquires BasicConfig, Management {
        // verify owner
        check_is_owner(owner);
        assert!(
            new_to_answers_pct + new_to_last_onlooker_pct <= 100,
            error::out_of_range(EINVALID_NUM)
        );
        let configs: &mut BasicConfig =
            borrow_global_mut<BasicConfig>(config_resource_address());
        // update
        configs.global_answer_allocate.to_answers_pct = new_to_answers_pct;
        configs.global_answer_allocate.to_last_onlooker_pct = new_to_last_onlooker_pct;
        configs.global_answer_allocate.to_platform_pct = 100 - new_to_answers_pct
            - new_to_last_onlooker_pct;
    }

    public entry fun update_global_onlook_allocate_by_owner(
        owner: &signer,
        update_below: bool,
        new_to_questioners_pct: u64,
        new_to_answers_pct: u64,
        new_to_last_onlooker_pct: u64
    ) acquires BasicConfig, Management {
        // verify owner
        check_is_owner(owner);
        assert!(
            new_to_questioners_pct + new_to_answers_pct + new_to_last_onlooker_pct
                <= 100,
            error::out_of_range(EINVALID_NUM)
        );
        let configs: &mut BasicConfig =
            borrow_global_mut<BasicConfig>(config_resource_address());
        // update
        let temp: &mut OnlookPhaseAllocate =
            if (update_below) {
                &mut configs.global_onlook_allocate_belowP
            } else {
                &mut configs.global_onlook_allocate_aboveP
            };
        temp.to_questioners_pct = new_to_questioners_pct;
        temp.to_answers_pct = new_to_answers_pct;
        temp.to_last_onlooker_pct = new_to_last_onlooker_pct;
        temp.to_platform_pct = 100 - new_to_questioners_pct - new_to_answers_pct
            - new_to_last_onlooker_pct;

    }

    inline fun check_is_admin_signer(user: &signer) acquires Management {
        let management: &Management =
            borrow_global<Management>(config_resource_address());
        assert!(
            signer::address_of(user) == management.admin_signer,
            error::unauthenticated(EUNAUTHORIZED)
        );
    }

    inline fun check_is_owner(user: &signer) acquires Management {
        let management: &Management =
            borrow_global<Management>(config_resource_address());
        assert!(
            signer::address_of(user) == management.owner,
            error::unauthenticated(EUNAUTHORIZED)
        );
    }

    // ======================================== view functions ==================================

    #[view]
    public fun config_resource_address(): address {
        account::create_resource_address(&@minter, CONFIG_SYMBOL)
    }

    #[view]
    public fun basic_config_details(): (u64, u64, u64, u64, u64, bool, u64, u64) acquires BasicConfig {
        let configs = borrow_global<BasicConfig>(config_resource_address());
        (
            configs.questioner_num_ul,
            configs.question_price_ll, // when create or follow a question
            configs.onlook_price_permille_ll, //%o
            configs.onlook_price_permille_ul,
            configs.global_const_P,
            configs.can_repeat_onlook,
            configs.onlook_single_extend_interval,
            configs.onlook_max_interval
        )
    }

    #[view]
    public fun question_resource_address(question_id: String): address {
        let question_id_vector: vector<u8> = *string::bytes(&question_id);
        account::create_resource_address(
            &config_resource_address(), question_id_vector
        )
    }

    #[view]
    public fun get_question_detail<CoinType>(
        question_id: String
    ): (
        u64,
        bool,
        u64,
        u64,
        vector<address>,
        Option<address>,
        u64,
        u64,
        u64,
        u64,
        u64,
        u64,
        address,
        bool,
        bool
    ) acquires Question {

        let question_addr: address = question_resource_address(question_id);
        assert!(
            exists<Question<CoinType>>(question_addr),
            error::not_found(EINVALID_ID)
        );
        let question = borrow_global<Question<CoinType>>(question_addr);
        let onlook_price: u64 =
            question.total_question_price * question.onlook_price_permille / 1000;

        (
            question.type,
            question.is_closed,
            question.answer_end_at,
            question.onlook_end_at,
            question.questioners,
            question.specified_answerer,
            question.total_question_price,
            onlook_price,
            question.total_onlook_num,
            question.total_answer_num,
            question.total_voted_weight_on_answer_phase,
            question.total_voted_weight_on_onlook_phase,
            question.last_onlooker_addr,
            question.has_claimed_last_onlooker_reward,
            question.has_claimed_platform_fee
        )
    }

    #[view]
    public fun get_questioner_detail<CoinType>(
        question_id: String, questioner: address
    ): (u64, address, bool) acquires Question {
        let question_addr: address = question_resource_address(question_id);
        assert!(
            exists<Question<CoinType>>(question_addr),
            error::not_found(EINVALID_ID)
        );
        let question = borrow_global<Question<CoinType>>(question_addr);
        // Aborts if there is no entry for `key`.
        let questioner_detail: &QuestionerDetail =
            smart_table::borrow(&question.questioner_details, questioner);
        (
            questioner_detail.quest_or_follow_price,
            questioner_detail.voted_to,
            questioner_detail.has_claimed_onlook_phase_reward
        )
    }

    #[view]
    public fun get_onlooker_detail<CoinType>(
        question_id: String, onlooker: address
    ): (u64, address) acquires Question {
        let question_addr: address = question_resource_address(question_id);
        assert!(
            exists<Question<CoinType>>(question_addr),
            error::not_found(EINVALID_ID)
        );
        let question = borrow_global<Question<CoinType>>(question_addr);
        // Aborts if there is no entry for `key`.
        let onlooker_detail: &OnlookerDetail =
            smart_table::borrow(&question.onlookers, onlooker);
        (onlooker_detail.onlook_num, onlooker_detail.voted_to)
    }

    #[view]
    public fun get_answer_detail<CoinType>(
        question_id: String, answerer: address
    ): (String, u64, u64, bool, bool) acquires Question {
        let question_addr: address = question_resource_address(question_id);
        assert!(
            exists<Question<CoinType>>(question_addr),
            error::not_found(EINVALID_ID)
        );
        let question = borrow_global<Question<CoinType>>(question_addr);
        // Aborts if there is no entry for `key`.
        let answerer_detail: &AnswerDetail =
            smart_table::borrow(&question.answer_vote_details, answerer);
        (
            answerer_detail.answer_id,
            answerer_detail.voted_weight_on_answer_phase,
            answerer_detail.voted_weight_on_onlook_phase,
            answerer_detail.has_claimd_answer_phase_reward,
            answerer_detail.has_claimd_onlook_phase_reward
        )
    }

    #[view]
    public fun get_onlook_allocate_detail<CoinType>(
        question_id: String
    ): (u64, u64, u64, u64, u64) acquires Question {
        let question_addr = question_resource_address(question_id);
        assert!(
            exists<Question<CoinType>>(question_addr),
            error::not_found(EINVALID_ID)
        );
        let question = borrow_global<Question<CoinType>>(question_addr);
        (
            question.onlook_allocate_detail.variable_P,
            question.onlook_allocate_detail.to_questioners_num,
            question.onlook_allocate_detail.to_answers_num,
            question.onlook_allocate_detail.to_last_onlooker_num,
            question.onlook_allocate_detail.to_platform_num
        )
    }

    #[view]
    public fun get_question_rewards<CoinType>(
        claimer_addr: address, question_id: String
    ): (u64, u64, u64, u64) acquires Question {
        // get question
        let question_addr = question_resource_address(question_id);
        assert!(
            exists<Question<CoinType>>(question_addr),
            error::not_found(EINVALID_ID)
        );
        let question = borrow_global<Question<CoinType>>(question_addr);
        // check: not close + not in answer phase(answer phase can't start claiming) + has answered
        let now_time = timestamp::now_seconds();
        assert!(
            !question.is_closed
                && now_time > question.answer_end_at
                && question.total_answer_num > 0,
            error::invalid_state(ECANNOT_CLAIM)
        );

        let is_questioner: bool = vector::contains(&question.questioners, &claimer_addr);
        let is_answerer: bool =
            smart_table::contains(&question.answer_vote_details, claimer_addr);
        let can_claim_num_as_answerer_phase1: u64 = 0;
        let can_claim_num_as_answerer_phase2: u64 = 0;
        let can_claim_num_as_questioner: u64 = 0;
        let can_claim_num_as_last_onlooker: u64 = 0;

        if (is_answerer) {
            let answer_detail: &AnswerDetail =
                smart_table::borrow(&question.answer_vote_details, claimer_addr);
            if (!answer_detail.has_claimd_answer_phase_reward) {
                let all_coins: u64 =
                    question.total_question_price
                        * question.answer_allocate.to_answers_pct / 100;
                if (question.total_voted_weight_on_answer_phase == 0) {
                    // distribute equally
                    can_claim_num_as_answerer_phase1 = all_coins
                        / question.total_answer_num;
                } else {
                    // distribute according to voted weight
                    can_claim_num_as_answerer_phase1 = ((all_coins as u128)
                        * (answer_detail.voted_weight_on_answer_phase as u128)
                        / (question.total_voted_weight_on_answer_phase as u128) as u64);

                };
            };

            if (now_time > question.onlook_end_at
                && !answer_detail.has_claimd_onlook_phase_reward) {
                let total_voted_weight =
                    question.total_voted_weight_on_answer_phase
                        + question.total_voted_weight_on_onlook_phase;
                if (total_voted_weight == 0) {
                    // distribute equally
                    can_claim_num_as_answerer_phase2 = question.onlook_allocate_detail.to_answers_num
                        / question.total_answer_num;

                } else {
                    // distribute according to voted weight
                    let answer_total_voted_weight =
                        answer_detail.voted_weight_on_answer_phase
                            + answer_detail.voted_weight_on_onlook_phase;
                    can_claim_num_as_answerer_phase2 = (
                        (question.onlook_allocate_detail.to_answers_num as u128)
                            * (answer_total_voted_weight as u128)
                            / (total_voted_weight as u128) as u64
                    );
                };
            };
        };

        // the second settlement -- answerer+ questioners + last onlooker + platform can claim
        if (now_time > question.onlook_end_at) {
            if (is_questioner) {
                let questioner_detail: &QuestionerDetail =
                    smart_table::borrow(&question.questioner_details, claimer_addr);
                if (!questioner_detail.has_claimed_onlook_phase_reward) {
                    can_claim_num_as_questioner = (
                        (question.onlook_allocate_detail.to_questioners_num as u128)
                            * (questioner_detail.quest_or_follow_price as u128)
                            / (question.total_question_price as u128) as u64
                    );

                };
            };

            // claimer is the last onlooker
            if (question.last_onlooker_addr == claimer_addr
                && !question.has_claimed_last_onlooker_reward) {
                let answer_phase_to_last_onlooker =
                    question.total_question_price
                        * question.answer_allocate.to_last_onlooker_pct / 100;
                can_claim_num_as_last_onlooker = answer_phase_to_last_onlooker
                    + question.onlook_allocate_detail.to_last_onlooker_num;
            }
        };

        (
            can_claim_num_as_answerer_phase1,
            can_claim_num_as_answerer_phase2,
            can_claim_num_as_questioner,
            can_claim_num_as_last_onlooker
        )
    }

    #[view]
    public fun get_last_onlooker_reward_by_now<CoinType>(
        question_id: String
    ): u64 acquires Question {
        // get question
        let question_addr = question_resource_address(question_id);
        assert!(
            exists<Question<CoinType>>(question_addr),
            error::not_found(EINVALID_ID)
        );
        let question = borrow_global<Question<CoinType>>(question_addr);
        // check: not close + not in answer phase(answer phase can't start claiming) + has answered
        let now_time = timestamp::now_seconds();
        assert!(
            !question.is_closed
                && now_time > question.answer_end_at
                && question.total_answer_num > 0,
            error::invalid_state(ECANNOT_CLAIM)
        );
        let answer_phase_to_last_onlooker =
            question.total_question_price
                * question.answer_allocate.to_last_onlooker_pct / 100;
        let onlooker_reward =
            answer_phase_to_last_onlooker
                + question.onlook_allocate_detail.to_last_onlooker_num;

        onlooker_reward
    }

    // ======================================== Unit Tests =========================================================== //

    #[test_only]
    use aptos_framework::account::create_account_for_test;
    #[test_only]
    use aptos_framework::aptos_coin::{Self, AptosCoin};
    // #[test_only]
    // use std::debug;
    #[test_only]
    public fun setup_test(
        aptos: &signer,
        resource_signer: &signer,
        creator: &signer,
        fee_recipient: &signer
    ) {
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(aptos);
        // create a fake account (only for testing purposes)
        create_account_for_test(signer::address_of(creator));
        create_account_for_test(signer::address_of(resource_signer));
        create_account_for_test(signer::address_of(fee_recipient));
        // add coin
        coin::register<AptosCoin>(creator);
        coin::register<AptosCoin>(fee_recipient);
        let coins = coin::mint(100_000_000_000_000, &mint_cap);
        coin::deposit(signer::address_of(creator), coins);

        timestamp::set_time_has_started_for_testing(aptos); // default timestamp:0
        init_module(resource_signer);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test_only]
    public fun create_public_question_for_test(
        creator: &signer,
        admin: &signer,
        question_id_str: String, // e.g. string::utf8(b"10001"),
        question_price: u64,
        onlook_price_permille: u64
    ): address acquires BasicConfig, Management {
        // // uint -->string ->vector<u8>
        // let question_id: u64 = 10001;
        // let question_id_str: String = to_string(&question_id);
        // let question_id_vector: vector<u8> = *string::bytes(&question_id_str);
        // debug::print(&question_id_vector);
        let question_account_addr = question_resource_address(question_id_str);
        let now_time = timestamp::now_seconds();
        // debug::print(&string::utf8(b"current time: "));
        // debug::print(&now_time);
        create_question<AptosCoin>(
            creator,
            admin,
            question_id_str,
            question_price,
            onlook_price_permille,
            QUESTION_TYPE_PUBLIC,
            option::none(),
            now_time + 1 * 60 * 60, // 1 hour
            now_time + 5 * 60 * 60 // 5 hour
        );
        // in a test unit, all event will be recorded together
        // only the latest event is for this user
        // let events = event::emitted_events<CreateQuestionEvent>();
        assert!(
            event::was_event_emitted<CreateQuestionEvent>(
                &CreateQuestionEvent {
                    creator: signer::address_of(creator),
                    question_id: question_id_str,
                    question_account_addr,
                    price: question_price
                }
            ),
            11
        );
        // return the question address
        question_account_addr
    }

    #[test_only]
    public fun create_specified_question_for_test(
        creator: &signer,
        admin: &signer,
        question_id_str: String, // e.g. string::utf8(b"10001"),
        question_price: u64,
        specified_answerer: Option<address>,
        onlook_price_permille: u64
    ): address acquires BasicConfig, Management {
        let question_account_addr = question_resource_address(question_id_str);
        let now_time = timestamp::now_seconds();
        // debug::print(&string::utf8(b"current time"));
        // debug::print(&now_time);
        create_question<AptosCoin>(
            creator,
            admin,
            question_id_str,
            question_price,
            onlook_price_permille,
            QUESTION_TYPE_SPECIFIED,
            specified_answerer,
            now_time + 1 * 60 * 60, // 1 hour
            now_time + 5 * 60 * 60 // 5hour
        );
        assert!(
            event::was_event_emitted<CreateQuestionEvent>(
                &CreateQuestionEvent {
                    creator: signer::address_of(creator),
                    question_id: question_id_str,
                    question_account_addr: question_account_addr,
                    price: question_price
                }
            ),
            22
        );
        // return the question address
        question_account_addr
    }

    #[test_only]
    public fun claim_question_rewards_for_test<CoinType>(
        claimer: &signer, question_id: String
    ): u64 acquires Question, FeeManagement {
        // claim
        claim_question_rewards<CoinType>(claimer, question_id);
        let events = event::emitted_events<RewardClaimedEvent>();
        let len = vector::length(&events);
        // debug::print(&events);
        // only the latest event is for this user
        let latest_event: &RewardClaimedEvent = vector::borrow(&events, len - 1);
        assert!(
            latest_event.claimer == signer::address_of(claimer)
                && latest_event.question_id == question_id,
            33
        );
        // return the claim amount
        latest_event.amount
    }
}
