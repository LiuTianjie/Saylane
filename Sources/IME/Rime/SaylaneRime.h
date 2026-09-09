#ifndef SAYLANE_RIME_H
#define SAYLANE_RIME_H
#include <stdint.h>
#include <stddef.h>
// Only this bridge knows librime's versioned C structs. All calls are serialized
// on the application's main thread; no Rime pointers escape a snapshot.
typedef uintptr_t SLSession;
typedef struct {
    char *input;
    char *preedit;
    char **candidates;
    size_t count;
    int has_more;
    int cursor;
    int sel_start;
    int sel_end;
} SLRimeSnapshot;
int SLRimeInitialize(const char *shared, const char *user);
const char *SLRimeVersion(void);
void SLRimeFinalize(void);
SLSession SLRimeCreate(const char *schema);
void SLRimeDestroy(SLSession session);
int SLRimeSelectSchema(SLSession session, const char *schema);
int SLRimeProcess(SLSession session, int key, int modifiers);
int SLRimeSelect(SLSession session, size_t index);
void SLRimeClear(SLSession session);
void SLRimeCommit(SLSession session);
char *SLRimeTakeCommit(SLSession session);
SLRimeSnapshot SLRimeRead(SLSession session, size_t limit);
void SLRimeFreeSnapshot(SLRimeSnapshot *snapshot);
void SLRimeFreeString(char *text);
#endif
