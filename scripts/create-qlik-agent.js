// Run inside the librechat container:
//   docker cp scripts/create-qlik-agent.js librechat:/tmp/create-qlik-agent.js
//   docker exec -w /app/api librechat node /tmp/create-qlik-agent.js
//
// Uses LibreChat's own model + permission service so the resulting agent is
// indistinguishable from one created through the UI.

process.chdir('/app/api');
const path = require('path');
require('module-alias/register');

// Pass the target user's MongoDB _id as argv[2], e.g.:
//   docker exec librechat node /tmp/create-qlik-agent.js 6a038b2d5efdb5737e874c7d
const USER_ID = process.argv[2];
if (!USER_ID) {
  console.error('Usage: node create-qlik-agent.js <user_object_id>');
  console.error('Find the user_id with:');
  console.error('  docker exec librechat-mongodb mongosh LibreChat --quiet --eval \\');
  console.error('    \'db.users.find({}, {_id:1, email:1}).toArray()\'');
  process.exit(1);
}

const INSTRUCTIONS = `/no_think
You are a Qlik Cloud MCP tool-calling agent. Do NOT think or reason. IMMEDIATELY call a tool.

You have NO internal knowledge about Qlik. You MUST call a tool for every question. Do NOT write text before calling a tool.

The tools below are available to you now. Call them by these exact names:

- qlik_search_mcp_qlik — find apps, data products, spaces, or any resource (use FIRST to find IDs)
- qlik_describe_app_mcp_qlik — get app details (needs app ID)
- qlik_list_sheets_mcp_qlik — list sheets (needs app ID)
- qlik_get_sheet_details_mcp_qlik — sheet details (needs app ID + sheet ID)
- qlik_get_chart_info_mcp_qlik — chart info (needs app ID + object ID)
- qlik_get_chart_data_mcp_qlik — chart data (needs app ID + object ID)
- qlik_list_dimensions_mcp_qlik — list dimensions (needs app ID)
- qlik_list_measures_mcp_qlik — list measures (needs app ID)
- qlik_get_fields_mcp_qlik — list fields (needs app ID)

To find apps: qlik_search_mcp_qlik with {"query":"app","resourceType":"app"}.
To find data products: qlik_search_mcp_qlik with {"resourceType":"dataproduct"}.
To find spaces: qlik_search_mcp_qlik with {"resourceType":"space"}.
Never ask the user for an ID — call qlik_search_mcp_qlik first to find it.
Present results with counts and bullet points. If empty, say "No results found."`;

const TOOLS = [
  'qlik_search_mcp_qlik',
  'qlik_describe_app_mcp_qlik',
  'qlik_list_sheets_mcp_qlik',
  'qlik_get_sheet_details_mcp_qlik',
  'qlik_get_chart_info_mcp_qlik',
  'qlik_get_chart_data_mcp_qlik',
  'qlik_list_dimensions_mcp_qlik',
  'qlik_list_measures_mcp_qlik',
  'qlik_get_fields_mcp_qlik',
];

(async () => {
  try {
    const mongoose = require('mongoose');
    await mongoose.connect(process.env.MONGO_URI);
    console.log('[ok] Mongo connected');

    const { nanoid } = require('nanoid');
    const db = require('~/models');
    const { grantPermission } = require('~/server/services/PermissionService');
    const {
      PrincipalType,
      ResourceType,
      AccessRoleIds,
    } = require('librechat-data-provider');

    const agentData = {
      id: `agent_${nanoid()}`,
      name: 'Qlik Assistant',
      description: 'Qlik Cloud MCP tool-calling agent (4 GB GPU tuned)',
      instructions: INSTRUCTIONS,
      provider: 'Ollama',
      model: 'qwen3:4b-nothinker',
      model_parameters: { temperature: 0 },
      tools: TOOLS,
      author: USER_ID,
      category: 'general',
      conversation_starters: [
        'What apps do I have in Qlik?',
        'List my data products',
        'Show me all spaces',
      ],
      recursion_limit: 25,
      end_after_tools: false,
      edges: [],
      versions: [],
    };

    const agent = await db.createAgent(agentData);
    console.log(`[ok] Agent created: ${agent.id} (_id=${agent._id})`);

    await Promise.all([
      grantPermission({
        principalType: PrincipalType.USER,
        principalId: USER_ID,
        resourceType: ResourceType.AGENT,
        resourceId: agent._id,
        accessRoleId: AccessRoleIds.AGENT_OWNER,
        grantedBy: USER_ID,
      }),
      grantPermission({
        principalType: PrincipalType.USER,
        principalId: USER_ID,
        resourceType: ResourceType.REMOTE_AGENT,
        resourceId: agent._id,
        accessRoleId: AccessRoleIds.REMOTE_AGENT_OWNER,
        grantedBy: USER_ID,
      }),
    ]);
    console.log('[ok] Granted owner permissions (agent + remoteAgent)');

    console.log('\nDone. The agent will appear in the sidebar after a page refresh.');
    process.exit(0);
  } catch (e) {
    console.error('[error]', e.message);
    console.error(e.stack);
    process.exit(1);
  }
})();
