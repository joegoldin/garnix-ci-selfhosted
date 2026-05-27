import { readFile } from "fs/promises";
import { MDXDocument } from "@/components/mdxDocument";
import { Modal, ModalActions, ModalSection } from "@/components/modal";
import { Button } from "@/components/button";
import { WithSidebar } from "@/components/withSidebar";
import styles from "./styles.module.css";

const Page = async () => {
  const source = await readFile("legal/terms.md", "utf-8");
  return (
    <WithSidebar>
      <main className={styles.container}>
        <Modal>
          <ModalSection>
            <MDXDocument source={source} />
          </ModalSection>
          <ModalSection className={styles.actionSection}>
            <ModalActions>
              <Button href="/signup/start">Close</Button>
            </ModalActions>
          </ModalSection>
        </Modal>
      </main>
    </WithSidebar>
  );
};

export default Page;
