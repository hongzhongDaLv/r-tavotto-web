export const privateDataExtension=/\.(?:rds|rda|rdata|csv|tsv|xlsx?|docx|parquet|feather|arrow|nc|tiff?|gpkg|sqlite3?|db|zip|7z|exe|msi|pem|key)$/i;
export const privateDirectory=/(?:^|\/)(?:runtime-data|runtime-[^/]+|local-data|user-data|imports|sessions|rendered|work|data|outputs?|results|test-output|rollback|backups|release|node_modules|\.wrangler|\.deploy-tools)\//i;
export const privateFilename=/(?:^|\/)(?:\.env(?:\.[^/]*)?|[^/]*(?:secrets|credentials)[^/]*\.json|[^/]*_render_state\.[^/]+|figure[^/]*\.(?:png|svg|pdf)|Rplots\.pdf)$/i;
export const privateProjectPath=/(?:E:(?:[\\/]|\\\\)+biodiversity data|C:(?:[\\/]|\\\\)+Users(?:[\\/]|\\\\)+ld|PSR_all_panels_20260913|Figures_FIXED_FULL)/i;
export const textExtension=/\.(?:html|js|mjs|cjs|css|json|txt|md|r)$/i;
const unreviewedDocumentation=/^docs\/(?:(?:audit|implementation|acceptance|feedback|compatibility|release-notes)\/|ci\/evidence\/)|^docs\/.*\.(?:png|jpe?g|pdf|svg)$/i;
const generatedVerification=/^tests\/(?:browser(?:-[^/]+)?-results\/|native-selection-verification\.json$|SELECTION_RELEASE_VERIFICATION\.md$|[^/]+-report\.json$)|^r-adapter\/[^/]+-report\.json$/i;

export function publicPathProblem(filename){
  const value=filename.replaceAll('\\','/');
  if(privateDataExtension.test(value))return 'private data or binary extension';
  if(unreviewedDocumentation.test(value))return 'unreviewed historical documentation evidence';
  if(generatedVerification.test(value))return 'local generated verification evidence';
  if(privateDirectory.test(value))return 'private or generated directory';
  if(privateFilename.test(value)&&value!=='.env.example'&&!value.endsWith('/.env.example'))return 'private or generated filename';
  return null;
}
