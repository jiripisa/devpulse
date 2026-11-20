use devpulse::protocol::*;

const FIXTURE: &str = include_str!("../../protocol/fixtures/snapshot-v1.json");

#[test]
fn fixture_decodes_with_expected_counts() {
    let s: Snapshot = serde_json::from_str(FIXTURE).unwrap();
    assert_eq!(s.my_pull_requests.len(), 2);
    assert_eq!(s.review_requests.len(), 2);
    assert_eq!(s.tickets.len(), 2);
    assert_eq!(s.sessions.len(), 3);
    assert_eq!(s.jira_base_url.as_deref(), Some("https://example.atlassian.net"));
    assert_eq!(s.sources.jira.state, SourceState::Error);
    assert_eq!(s.sources.jira.message.as_deref(), Some("Jira returned 401"));
    let pr = &s.my_pull_requests[0];
    assert_eq!(pr.checks, CheckState::Pending);
    assert_eq!(pr.review_decision, ReviewDecision::ReviewRequired);
    assert_eq!(pr.jira_key.as_deref(), Some("STORE-2474"));
    assert_eq!(pr.recent_comments[0].author_name.as_deref(), Some("Alice Nováková"));
    assert_eq!(pr.recent_comments[1].author_kind, AuthorKind::Copilot);
    assert_eq!(s.tickets[0].status_category, StatusCategory::InProgress);
    assert_eq!(s.sessions[1].status, SessionStatus::Waiting);
    assert_eq!(s.sessions[1].waiting_for.as_deref(), Some("permission prompt"));
}

#[test]
fn fixture_wrapped_in_a_server_message_decodes() {
    let line = format!(r#"{{"type":"snapshot","protocol":1,"data":{}}}"#, FIXTURE.replace('\n', " "));
    match serde_json::from_str::<ServerMessage>(&line).unwrap() {
        ServerMessage::Snapshot { data, .. } => assert_eq!(data.sessions.len(), 3),
        other => panic!("unexpected {other:?}"),
    }
}

#[test]
fn unknown_enum_values_and_fields_are_tolerated() {
    let json = FIXTURE
        .replace("\"pending\"", "\"brandNew\"")
        .replace("\"busy\"", "\"hyperactive\"")
        .replace("\"appVersion\"", "\"future\": 1, \"appVersion\"");
    let s: Snapshot = serde_json::from_str(&json).unwrap();
    assert_eq!(s.my_pull_requests[0].checks, CheckState::Unknown);
    assert_eq!(s.sessions[0].status, SessionStatus::Unknown);
}

#[test]
fn client_messages_encode_to_the_wire_form() {
    let enc = |m: &ClientMessage| serde_json::to_string(m).unwrap();
    assert_eq!(enc(&ClientMessage::Hello { protocol: 1 }), r#"{"type":"hello","protocol":1}"#);
    assert_eq!(enc(&ClientMessage::Refresh), r#"{"type":"refresh"}"#);
    assert_eq!(enc(&ClientMessage::OpenSettings), r#"{"type":"openSettings"}"#);
    assert_eq!(enc(&ClientMessage::Upgrade), r#"{"type":"upgrade"}"#);
    assert_eq!(
        enc(&ClientMessage::Open { kind: OpenKind::JiraForPr, id: "x".into() }),
        r#"{"type":"open","kind":"jiraForPr","id":"x"}"#
    );
}

#[test]
fn upgrade_messages_decode() {
    let m: ServerMessage =
        serde_json::from_str(r#"{"type":"upgrade","phase":"downloading","progress":0.5}"#).unwrap();
    match m {
        ServerMessage::Upgrade { phase, progress, message } => {
            assert_eq!(phase, UpgradePhase::Downloading);
            assert_eq!(progress, Some(0.5));
            assert_eq!(message, None);
        }
        other => panic!("unexpected {other:?}"),
    }
    let m: ServerMessage = serde_json::from_str(r#"{"type":"somethingNew","x":1}"#).unwrap();
    assert!(matches!(m, ServerMessage::Unknown));
}
