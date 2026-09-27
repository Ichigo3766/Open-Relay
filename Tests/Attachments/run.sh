#!/bin/sh
set -eu
# Pass an external artifact directory; no generated files enter the checkout.
work=${1:?Usage: sh Tests/Attachments/run.sh /path/to/artifacts}
mkdir -p "$work"
for suite in RegressionTests ContextTests; do
    xcrun swiftc -module-cache-path "$work/ModuleCache" -o "$work/$suite" "Tests/Attachments/$suite.swift" \
        'Open UI/Core/Models/ChatMessage.swift' \
        'Open UI/Core/Models/MessageHistory.swift' \
        'Open UI/Core/Models/KnowledgeItem.swift'
    "$work/$suite"
done
for suite in SearchTests SearchAPITests; do
    set --
    if [ "$suite" = SearchAPITests ]; then
        set -- 'Open UI/Core/Networking/APIClient+AttachmentSearch.swift'
    fi
    xcrun swiftc -module-cache-path "$work/ModuleCache" -o "$work/$suite" "Tests/Attachments/$suite.swift" \
        'Open UI/Core/Models/ChatMessage.swift' \
        'Open UI/Core/Models/KnowledgeItem.swift' \
        'Open UI/Core/Models/AttachmentUsage.swift' \
        'Open UI/Core/Models/ChatAdvancedParams.swift' \
        'Open UI/Core/Models/UserDefaultParams.swift' \
        'Open UI/Features/Chat/ViewModels/AttachmentSearchModel.swift' \
        "$@"
    "$work/$suite"
done
