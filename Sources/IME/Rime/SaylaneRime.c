#include "SaylaneRime.h"
#include <rime_api.h>
#include <stdlib.h>
#include <string.h>

static RimeApi *api;
static int initialized;

int SLRimeInitialize(const char *shared, const char *user) {
    if (initialized) return 1;
    api = rime_get_api();
    if (!RIME_PROVIDED(api, candidate_list_from_index)) return 0;
    RIME_STRUCT(RimeTraits, traits);
    traits.shared_data_dir = shared;
    traits.user_data_dir = user;
    traits.distribution_name = "Saylane";
    traits.distribution_code_name = "saylane";
    traits.distribution_version = "1";
    traits.app_name = "rime.saylane";
    traits.min_log_level = 2;
    traits.log_dir = "";
    api->setup(&traits);
    api->initialize(&traits);
    // Dictionaries are compiled at build time, never on an input event.
    initialized = 1;
    return 1;
}

const char *SLRimeVersion(void) { return api ? api->get_version() : "unavailable"; }
SLSession SLRimeCreate(const char *schema) {
    if (!initialized) return 0;
    RimeSessionId session = api->create_session();
    if (!session) return 0;
    if (!api->select_schema(session, schema)) {
        api->destroy_session(session);
        return 0;
    }
    api->set_option(session, "ascii_mode", 0);
    return session;
}
void SLRimeDestroy(SLSession s) { if (s && api && initialized) api->destroy_session(s); }
void SLRimeFinalize(void) {
    if (initialized) {
        api->finalize(); // close sessions and flush the user dictionary on clean exit
        initialized = 0;
    }
}
int SLRimeSelectSchema(SLSession s, const char *schema) { return api->select_schema(s, schema); }
int SLRimeProcess(SLSession s, int key, int modifiers) { return api->process_key(s, key, modifiers); }
int SLRimeSelect(SLSession s, size_t index) { return api->select_candidate(s, index); }
void SLRimeClear(SLSession s) { api->clear_composition(s); }
void SLRimeCommit(SLSession s) { api->commit_composition(s); }
char *SLRimeTakeCommit(SLSession s) {
    RIME_STRUCT(RimeCommit, commit);
    if (!api->get_commit(s, &commit)) return NULL;
    char *text = strdup(commit.text ? commit.text : "");
    api->free_commit(&commit);
    return text;
}
SLRimeSnapshot SLRimeRead(SLSession s, size_t limit) {
    SLRimeSnapshot result = {0};
    const char *input = api->get_input(s);
    result.input = strdup(input ? input : "");
    RIME_STRUCT(RimeContext, context);
    if (api->get_context(s, &context)) {
        result.preedit = strdup(context.composition.preedit ? context.composition.preedit : "");
        result.cursor = context.composition.cursor_pos;
        result.sel_start = context.composition.sel_start;
        result.sel_end = context.composition.sel_end;
        api->free_context(&context);
    }
    result.candidates = calloc(limit, sizeof(char *));
    if (!result.candidates) return result;
    RimeCandidateListIterator iterator = {0};
    if (api->candidate_list_begin(s, &iterator)) {
        while (result.count < limit && api->candidate_list_next(&iterator)) {
            result.candidates[result.count++] = strdup(iterator.candidate.text ? iterator.candidate.text : "");
        }
        result.has_more = api->candidate_list_next(&iterator);
        api->candidate_list_end(&iterator);
    }
    return result;
}
void SLRimeFreeSnapshot(SLRimeSnapshot *snapshot) {
    free(snapshot->input);
    free(snapshot->preedit);
    for (size_t i = 0; i < snapshot->count; ++i) free(snapshot->candidates[i]);
    free(snapshot->candidates);
    memset(snapshot, 0, sizeof(*snapshot));
}
void SLRimeFreeString(char *text) { free(text); }
